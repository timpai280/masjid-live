import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'bg.dart';
import 'broadcast.dart';
import 'common.dart';
import 'config.dart';
import 'push.dart';
import 'sessions.dart';
import 'strings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  lang.value = prefs.getString('lang') ?? 'en';
  Api.baseUrl = prefs.getString('serverUrl') ?? kServerUrl;
  await Push.init();
  runApp(const MasjidLiveApp());
}

class MasjidLiveApp extends StatelessWidget {
  const MasjidLiveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: lang,
      builder: (context, l, _) => MaterialApp(
        title: 'Masjid Live',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: kGreen, useMaterial3: true),
        builder: (context, child) => Directionality(
          textDirection: l == 'ur' ? TextDirection.rtl : TextDirection.ltr,
          child: child ?? const SizedBox(),
        ),
        home: const ListenScreen(),
      ),
    );
  }
}

// =====================================================================
//  LISTEN SCREEN (default screen)
// =====================================================================
enum LState { idle, connecting, waiting, playing }

class ListenScreen extends StatefulWidget {
  const ListenScreen({super.key});
  @override
  State<ListenScreen> createState() => _ListenState();
}

class _ListenState extends State<ListenScreen> with LangAware<ListenScreen> {
  final _idCtl = TextEditingController();
  String? _id;
  String _name = '';
  String _status = 'offline'; // offline | live | paused | ended
  int _listeners = 0;
  String _schedule = '';
  LState _state = LState.idle;
  String _joinErr = '';
  String _err = '';
  String _note = '';
  bool _busy = false;
  Room? _room;
  EventsListener<RoomEvent>? _lis;
  Timer? _poll;
  StreamSubscription<dynamic>? _openedSub;

  bool get _connected => _state != LState.idle;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final open = await Push.initialOpen();
    _openedSub = Push.onOpened(_openFromPush);
    if (Api.baseUrl.trim().isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _askServer());
      return;
    }
    final saved = open?.mosqueId ?? prefs.getString('mosqueId') ?? (kDefaultMosqueId.isNotEmpty ? kDefaultMosqueId : null);
    if (saved != null && saved.isNotEmpty) {
      _idCtl.text = saved;
      await _join(saved);
      if (open != null && open.type == 'live' && _id != null) await _start();
    }
  }

  /// User tapped a notification while the app was in the background.
  Future<void> _openFromPush(PushOpen open) async {
    if (_id != open.mosqueId) {
      await _stop();
      await _join(open.mosqueId);
    } else {
      await _refresh();
    }
    if (open.type == 'live' && _id != null && _state == LState.idle) await _start();
  }

  void _setState(LState s) {
    if (!mounted) return;
    setState(() => _state = s);
  }

  /// New status from the server. When the lecturer ends the lesson, everyone is disconnected.
  void _applyStatus(String s) {
    if (s.isEmpty || !mounted) return;
    final prev = _status;
    setState(() => _status = s);
    if (s == 'ended' && isOnAir(prev) && _connected) {
      _stop(note: tr('endedNote'));
    }
  }

  void _readInfo(Map<String, dynamic> j) {
    _name = (j['name'] ?? _name).toString();
    _listeners = (j['listeners'] as num?)?.toInt() ?? 0;
    final sch = j['schedule'];
    _schedule = sch is Map ? (sch['text'] ?? '').toString() : '';
  }

  String _statusFrom(Map<String, dynamic> j) {
    final s = j['status'];
    if (s is String && s.isNotEmpty) return s;
    return j['live'] == true ? 'live' : 'offline';
  }

  Future<void> _join(String raw) async {
    final id = raw.trim().toUpperCase();
    if (id.isEmpty) return;
    if (Api.baseUrl.trim().isEmpty) {
      setState(() => _joinErr = tr('needServer'));
      return;
    }
    setState(() {
      _busy = true;
      _joinErr = '';
    });
    try {
      final j = await Api.mosque(id);
      final newId = j['id'].toString();
      final old = prefs.getString('mosqueId');
      await prefs.setString('mosqueId', newId);
      Push.follow(old, newId);
      if (!mounted) return;
      setState(() {
        _id = newId;
        _readInfo(j);
        _status = _statusFrom(j);
      });
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
      Permission.notification.request();
    } catch (e) {
      if (mounted) setState(() => _joinErr = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    final id = _id;
    if (id == null) return;
    try {
      final j = await Api.mosque(id);
      if (!mounted || _id != id) return;
      setState(() => _readInfo(j));
      _applyStatus(_statusFrom(j));
    } catch (_) {}
  }

  Future<void> _start() async {
    final id = _id;
    if (id == null) return;
    setState(() {
      _err = '';
      _note = '';
      _state = LState.connecting;
    });
    try {
      final j = await Api.post('/api/listen', {'mosqueId': id});
      final room = Room(roomOptions: RoomOptions(adaptiveStream: false, dynacast: false));
      final lis = room.createListener();
      lis
        ..on<TrackSubscribedEvent>((e) {
          if (e.track is RemoteAudioTrack) {
            useMediaAudio(true);
            _setState(LState.playing);
            _refresh();
          }
        })
        ..on<TrackUnsubscribedEvent>((e) {
          if (e.track is RemoteAudioTrack && _state != LState.idle) {
            _setState(LState.waiting);
          }
        })
        ..on<RoomMetadataChangedEvent>((e) => _applyStatus(parseStatus(e.metadata)))
        ..on<RoomDisconnectedEvent>((_) {
          if (identical(_room, room)) _stop();
        });
      _room = room;
      _lis = lis;
      await useMediaAudio(true);
      await BgService.start(mic: false, title: _name, text: tr('playing'));
      await room.connect(j['url'].toString(), j['token'].toString());
      await useMediaAudio(true);
      if (_state == LState.connecting) _setState(LState.waiting);
      final s = parseStatus(room.metadata);
      if (s.isNotEmpty && mounted) setState(() => _status = s);
    } catch (e) {
      await _stop();
      if (mounted) setState(() => _err = errText(e));
    }
  }

  Future<void> _stop({String note = ''}) async {
    final r = _room;
    final l = _lis;
    _room = null;
    _lis = null;
    if (mounted) {
      setState(() {
        _state = LState.idle;
        if (note.isNotEmpty) _note = note;
      });
    }
    await BgService.stop();
    try {
      await r?.disconnect();
    } catch (_) {}
    try {
      l?.dispose();
    } catch (_) {}
    try {
      r?.dispose();
    } catch (_) {}
  }

  Future<void> _changeMosque() async {
    await _stop();
    _poll?.cancel();
    final id = _id;
    if (id != null) Push.unfollow(id);
    await prefs.remove('mosqueId');
    if (mounted) {
      setState(() {
        _id = null;
        _note = '';
      });
    }
  }

  Future<void> _openSessions() async {
    final id = _id;
    if (id == null) return;
    if (_connected) await _stop();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SessionsScreen(mosqueId: id, mosqueName: _name)));
  }

  Future<void> _askServer() async {
    final ctl = TextEditingController(text: Api.baseUrl);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('serverSettings')),
        content: TextField(
          controller: ctl,
          keyboardType: TextInputType.url,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(hintText: 'https://masjidlive.duckdns.org'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: Text(tr('save'))),
        ],
      ),
    );
    if (v == null) return;
    var url = v;
    if (url.isNotEmpty && !url.startsWith('http')) url = 'https://$url';
    if (url.isEmpty) {
      await prefs.remove('serverUrl');
      Api.baseUrl = kServerUrl;
    } else {
      await prefs.setString('serverUrl', url);
      Api.baseUrl = url;
    }
    if (mounted) setState(() => _joinErr = '');
  }

  @override
  void dispose() {
    _poll?.cancel();
    _openedSub?.cancel();
    _stop();
    _idCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kGreen,
        foregroundColor: Colors.white,
        title: Text(tr('appName')),
        actions: [
          langButton(),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'server') _askServer();
            },
            itemBuilder: (_) => [PopupMenuItem(value: 'server', child: Text(tr('serverSettings')))],
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (_id == null) _joinCard() else _playerCard(),
              const SizedBox(height: 24),
              Center(
                child: TextButton.icon(
                  icon: const Icon(Icons.mic),
                  label: Text(tr('iAmBroadcaster')),
                  onPressed: () async {
                    if (_state != LState.idle) await _stop();
                    if (!context.mounted) return;
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BroadcastScreen()));
                    _refresh();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _joinCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('enterId'), style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 10),
            TextField(
              controller: _idCtl,
              textCapitalization: TextCapitalization.characters,
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 22),
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'JMFM'),
              onSubmitted: _join,
            ),
            const SizedBox(height: 14),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kGreen, padding: const EdgeInsets.all(16)),
              onPressed: _busy ? null : () => _join(_idCtl.text),
              child: Text(tr('connect'), style: const TextStyle(fontSize: 18)),
            ),
            if (_joinErr.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_joinErr, style: const TextStyle(color: kRed, fontSize: 15)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _playerCard() {
    final active = _state != LState.idle;
    final stateText = switch (_state) {
      LState.idle => tr('tapToListen'),
      LState.connecting => tr('connecting'),
      LState.waiting => tr('waiting'),
      LState.playing => _status == 'paused' ? tr('pausedListener') : tr('playing'),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text(tr('mosque'), style: const TextStyle(color: Colors.grey)),
            Text(_name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            Text(_id ?? '', textDirection: TextDirection.ltr, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 10),
            statusBadge(_status),
            if (isOnAir(_status))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('$_listeners ${tr('listeners')}', style: const TextStyle(color: Colors.grey)),
              ),
            if (_schedule.isNotEmpty) scheduleCard(_schedule),
            const SizedBox(height: 20),
            SizedBox(
              width: 160,
              height: 160,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  shape: const CircleBorder(),
                  backgroundColor: active ? kRed : kGreen,
                  foregroundColor: Colors.white,
                ),
                onPressed: _state == LState.connecting ? null : (active ? () => _stop() : _start),
                child: _state == LState.connecting
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Icon(active ? Icons.stop : Icons.play_arrow, size: 80),
              ),
            ),
            const SizedBox(height: 14),
            Text(stateText,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: _status == 'paused' && active ? kOrange : null)),
            if (_note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_note, textAlign: TextAlign.center, style: const TextStyle(color: kGreen, fontSize: 15)),
              ),
            if (_err.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_err, textAlign: TextAlign.center, style: const TextStyle(color: kRed)),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.edit_note),
                    label: Text(tr('askQuestion'), textAlign: TextAlign.center),
                    onPressed: () => askQuestion(context, _id!),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.history),
                    label: Text(tr('pastSessions'), textAlign: TextAlign.center),
                    onPressed: _openSessions,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextButton(onPressed: _changeMosque, child: Text(tr('changeMosque'))),
          ],
        ),
      ),
    );
  }
}
