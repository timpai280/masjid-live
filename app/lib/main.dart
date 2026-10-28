import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'bg.dart';
import 'config.dart';
import 'push.dart';
import 'strings.dart';

const kGreen = Color(0xFF0F7B5F);
const kRed = Color(0xFFD93025);
late SharedPreferences prefs;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  lang.value = prefs.getString('lang') ?? 'en';
  Api.baseUrl = prefs.getString('serverUrl') ?? kServerUrl;
  await Push.init();
  runApp(const MasjidLiveApp());
}

void toggleLang() {
  lang.value = lang.value == 'en' ? 'ur' : 'en';
  prefs.setString('lang', lang.value);
}

String errText(Object e) {
  final code = e is ApiException ? e.code : 'error';
  final key = 'err_$code';
  final s = tr(key);
  return s == key ? tr('err_error') : s;
}

/// Speaker settings: listeners use "media" mode (loudspeaker, media volume),
/// the lecturer uses "communication" mode (echo cancellation for the mic).
Future<void> useMediaAudio(bool media) async {
  try {
    await rtc.Helper.setAndroidAudioConfiguration(
        media ? rtc.AndroidAudioConfiguration.media : rtc.AndroidAudioConfiguration.communication);
  } catch (e) {
    debugPrint('audio config: $e');
  }
  if (media) {
    try {
      await Hardware.instance.setSpeakerphoneOn(true);
    } catch (_) {}
  }
}

/// Rebuild the screen when the language changes.
mixin LangAware<T extends StatefulWidget> on State<T> {
  void _onLang() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    lang.addListener(_onLang);
  }

  @override
  void dispose() {
    lang.removeListener(_onLang);
    super.dispose();
  }
}

Widget langButton() => TextButton(
      onPressed: toggleLang,
      child: Text(isUrdu ? 'English' : 'اردو', style: const TextStyle(color: Colors.white, fontSize: 16)),
    );

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
  bool _live = false;
  int _listeners = 0;
  LState _state = LState.idle;
  String _joinErr = '';
  String _err = '';
  bool _busy = false;
  Room? _room;
  EventsListener<RoomEvent>? _lis;
  Timer? _poll;
  StreamSubscription<dynamic>? _openedSub;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final pushId = await Push.initialLiveMosque();
    _openedSub = Push.onOpened(_openFromPush);
    if (Api.baseUrl.trim().isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _askServer());
      return;
    }
    final saved = pushId ?? prefs.getString('mosqueId');
    if (saved != null && saved.isNotEmpty) {
      _idCtl.text = saved;
      await _join(saved);
      if (pushId != null && _id != null) await _start();
    }
  }

  /// User tapped a "Tafseer is LIVE" notification while the app was in the background.
  Future<void> _openFromPush(String id) async {
    if (_id != id) {
      await _stop();
      await _join(id);
    }
    if (_id != null && _state == LState.idle) await _start();
  }

  void _setState(LState s) {
    if (!mounted) return;
    setState(() => _state = s);
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
        _name = (j['name'] ?? '').toString();
        _live = j['live'] == true;
        _listeners = (j['listeners'] as num?)?.toInt() ?? 0;
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
      setState(() {
        _name = (j['name'] ?? _name).toString();
        _live = j['live'] == true;
        _listeners = (j['listeners'] as num?)?.toInt() ?? 0;
      });
    } catch (_) {}
  }

  Future<void> _start() async {
    final id = _id;
    if (id == null) return;
    setState(() {
      _err = '';
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
            _refresh();
          }
        })
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
    } catch (e) {
      await _stop();
      if (mounted) setState(() => _err = errText(e));
    }
  }

  Future<void> _stop() async {
    final r = _room;
    final l = _lis;
    _room = null;
    _lis = null;
    _setState(LState.idle);
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
    if (mounted) setState(() => _id = null);
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
          decoration: const InputDecoration(hintText: 'https://yourmasjid.duckdns.org'),
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
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'TEST01'),
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
      LState.playing => tr('playing'),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text(tr('mosque'), style: const TextStyle(color: Colors.grey)),
            Text(_name,
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            Text(_id ?? '', textDirection: TextDirection.ltr, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                color: _live ? kRed : Colors.grey.shade300,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _live ? '● ${tr('live')}' : tr('offline'),
                style: TextStyle(color: _live ? Colors.white : Colors.black54, fontWeight: FontWeight.bold),
              ),
            ),
            if (_live)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('$_listeners ${tr('listeners')}', style: const TextStyle(color: Colors.grey)),
              ),
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
                onPressed: _state == LState.connecting ? null : (active ? _stop : _start),
                child: _state == LState.connecting
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Icon(active ? Icons.stop : Icons.play_arrow, size: 80),
              ),
            ),
            const SizedBox(height: 14),
            Text(stateText, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
            if (_err.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_err, textAlign: TextAlign.center, style: const TextStyle(color: kRed)),
              ),
            const SizedBox(height: 10),
            TextButton(onPressed: _changeMosque, child: Text(tr('changeMosque'))),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
//  BROADCAST SCREEN (lecturer)
// =====================================================================
class BroadcastScreen extends StatefulWidget {
  const BroadcastScreen({super.key});
  @override
  State<BroadcastScreen> createState() => _BroadcastState();
}

class _BroadcastState extends State<BroadcastScreen> with LangAware<BroadcastScreen> {
  final _idCtl = TextEditingController(text: prefs.getString('bMosqueId') ?? '');
  final _pinCtl = TextEditingController();
  bool _busy = false;
  bool _live = false;
  bool _reconnecting = false;
  String _err = '';
  String _name = '';
  String _mid = '';
  int _listeners = 0;
  DateTime? _startedAt;
  Timer? _tick;
  Timer? _poll;
  Room? _room;
  EventsListener<RoomEvent>? _lis;

  String get _elapsed {
    final s = _startedAt == null ? 0 : DateTime.now().difference(_startedAt!).inSeconds;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(s ~/ 3600)}:${two(s ~/ 60 % 60)}:${two(s % 60)}';
  }

  Future<void> _goLive() async {
    final id = _idCtl.text.trim().toUpperCase();
    final pin = _pinCtl.text.trim();
    if (id.isEmpty || pin.isEmpty) return;
    if (Api.baseUrl.trim().isEmpty) {
      setState(() => _err = tr('needServer'));
      return;
    }
    setState(() {
      _busy = true;
      _err = '';
    });
    try {
      final mic = await Permission.microphone.request();
      if (!mic.isGranted) throw ApiException('mic');
      await Permission.notification.request();

      final j = await Api.post('/api/broadcast/token', {'mosqueId': id, 'pin': pin});
      final m = j['mosque'];
      final name = (m is Map ? m['name'] : null)?.toString() ?? id;
      await prefs.setString('bMosqueId', id);

      // Foreground service first, so the mic keeps working with the screen locked
      await BgService.start(mic: true, title: tr('youAreLive'), text: name);
      await useMediaAudio(false);

      final room = Room(
        roomOptions: RoomOptions(
          defaultAudioCaptureOptions: AudioCaptureOptions(
            echoCancellation: true,
            noiseSuppression: true,
            autoGainControl: true,
          ),
        ),
      );
      final lis = room.createListener();
      lis
        ..on<RoomDisconnectedEvent>((_) {
          if (identical(_room, room)) _end(showMsg: true);
        })
        ..on<RoomReconnectingEvent>((_) {
          if (mounted) setState(() => _reconnecting = true);
        })
        ..on<RoomReconnectedEvent>((_) {
          if (mounted) setState(() => _reconnecting = false);
        });
      _room = room;
      _lis = lis;
      await room.connect(j['url'].toString(), j['token'].toString());
      await room.localParticipant?.setMicrophoneEnabled(true);

      _mid = id;
      // Tell the server we are live -> it sends the "Tafseer is LIVE" notification
      Api.post('/api/broadcast/live', {'mosqueId': id, 'pin': pin}).catchError((_) => <String, dynamic>{});

      if (!mounted) return;
      setState(() {
        _live = true;
        _name = name;
        _startedAt = DateTime.now();
        _listeners = 0;
      });
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      _poll = Timer.periodic(const Duration(seconds: 10), (_) => _pollCount());
    } catch (e) {
      await _end();
      if (mounted) setState(() => _err = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pollCount() async {
    try {
      final j = await Api.mosque(_mid);
      if (mounted) setState(() => _listeners = (j['listeners'] as num?)?.toInt() ?? 0);
    } catch (_) {}
  }

  Future<void> _end({bool showMsg = false}) async {
    _tick?.cancel();
    _poll?.cancel();
    _tick = null;
    _poll = null;
    final r = _room;
    final l = _lis;
    _room = null;
    _lis = null;
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
    if (mounted) {
      setState(() {
        _live = false;
        _reconnecting = false;
        if (showMsg) _err = tr('ended');
      });
    }
  }

  Future<void> _confirmEnd() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(tr('endConfirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('endLive')),
          ),
        ],
      ),
    );
    if (ok == true) await _end(showMsg: true);
  }

  @override
  void dispose() {
    _end();
    _idCtl.dispose();
    _pinCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_live,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: kGreen,
          foregroundColor: Colors.white,
          title: Text(tr('broadcast')),
          actions: [langButton()],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [_live ? _liveCard() : _loginCard()],
          ),
        ),
      ),
    );
  }

  Widget _loginCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('enterId'), style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            TextField(
              controller: _idCtl,
              textCapitalization: TextCapitalization.characters,
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 22),
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'TEST01'),
            ),
            const SizedBox(height: 14),
            Text(tr('pin'), style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            TextField(
              controller: _pinCtl,
              obscureText: true,
              keyboardType: TextInputType.number,
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 22),
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: kRed, padding: const EdgeInsets.all(18)),
              onPressed: _busy ? null : _goLive,
              icon: _busy
                  ? const SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.mic),
              label: Text(tr('goLive'), style: const TextStyle(fontSize: 20)),
            ),
            if (_err.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_err, style: const TextStyle(color: kRed, fontSize: 15)),
              ),
            const SizedBox(height: 12),
            Text(tr('lockOk'), style: const TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _liveCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(color: kRed, borderRadius: BorderRadius.circular(20)),
              child: Text('● ${tr('youAreLive')}',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            const SizedBox(height: 14),
            Text(_name,
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text(_elapsed,
                textDirection: TextDirection.ltr,
                style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold, fontFeatures: [
                  FontFeature.tabularFigures(),
                ])),
            Text('$_listeners ${tr('listeners')}', style: const TextStyle(fontSize: 16, color: Colors.grey)),
            if (_reconnecting)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(tr('reconnecting'), style: const TextStyle(color: Colors.orange)),
              ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: kRed, padding: const EdgeInsets.all(18)),
                onPressed: _confirmEnd,
                icon: const Icon(Icons.stop),
                label: Text(tr('endLive'), style: const TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(height: 12),
            Text(tr('lockOk'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
