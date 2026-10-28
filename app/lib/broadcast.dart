import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';

import 'api.dart';
import 'bg.dart';
import 'common.dart';
import 'config.dart';
import 'strings.dart';

// =====================================================================
//  BROADCAST SCREEN (lecturer): login -> dashboard -> live (pause/resume/end)
// =====================================================================
class BroadcastScreen extends StatefulWidget {
  const BroadcastScreen({super.key});
  @override
  State<BroadcastScreen> createState() => _BroadcastState();
}

class _BroadcastState extends State<BroadcastScreen> with LangAware<BroadcastScreen> {
  final _idCtl = TextEditingController(text: prefs.getString('bMosqueId') ?? kDefaultMosqueId);
  final _pinCtl = TextEditingController();
  String? _mid;
  String? _pin;
  String _name = '';
  String _schedule = '';
  int _qCount = 0;
  bool _busy = false;
  bool _live = false;
  bool _paused = false;
  bool _reconnecting = false;
  String _err = '';
  String _info = '';
  int _listeners = 0;
  DateTime? _startedAt;
  Timer? _tick;
  Timer? _poll;
  Room? _room;
  EventsListener<RoomEvent>? _lis;

  Map<String, dynamic> get _creds => {'mosqueId': _mid, 'pin': _pin};

  String get _elapsed {
    final s = _startedAt == null ? 0 : DateTime.now().difference(_startedAt!).inSeconds;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(s ~/ 3600)}:${two(s ~/ 60 % 60)}:${two(s % 60)}';
  }

  void _readLogin(Map<String, dynamic> j) {
    final m = j['mosque'];
    _name = (m is Map ? m['name'] : null)?.toString() ?? (_mid ?? '');
    final sch = j['schedule'];
    _schedule = sch is Map ? (sch['text'] ?? '').toString() : '';
    _qCount = (j['questions'] as num?)?.toInt() ?? 0;
  }

  Future<void> _login() async {
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
      final j = await Api.post('/api/broadcast/login', {'mosqueId': id, 'pin': pin});
      await prefs.setString('bMosqueId', id);
      if (!mounted) return;
      setState(() {
        _mid = id;
        _pin = pin;
        _info = '';
        _readLogin(j);
      });
    } catch (e) {
      if (mounted) setState(() => _err = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reloadInfo() async {
    if (_mid == null) return;
    try {
      final j = await Api.post('/api/broadcast/login', _creds);
      if (mounted) setState(() => _readLogin(j));
    } catch (_) {}
  }

  void _logout() {
    setState(() {
      _mid = null;
      _pin = null;
      _pinCtl.clear();
      _info = '';
      _err = '';
    });
  }

  Future<void> _goLive() async {
    setState(() {
      _busy = true;
      _err = '';
      _info = '';
    });
    try {
      final mic = await Permission.microphone.request();
      if (!mic.isGranted) throw ApiException('mic');
      await Permission.notification.request();

      final j = await Api.post('/api/broadcast/token', _creds);

      // Foreground service first, so the mic keeps working with the screen locked
      await BgService.start(mic: true, title: tr('youAreLive'), text: _name);
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
          if (identical(_room, room)) _disconnect(showMsg: true);
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

      // Tell the server: lesson started -> listeners see LIVE, recording starts, notification is sent
      try {
        await Api.post('/api/broadcast/state', {..._creds, 'state': 'live'});
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _live = true;
        _paused = false;
        _startedAt = DateTime.now();
        _listeners = 0;
      });
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      _poll = Timer.periodic(const Duration(seconds: 10), (_) => _pollCount());
    } catch (e) {
      await _disconnect();
      if (mounted) setState(() => _err = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _togglePause() async {
    final room = _room;
    if (room == null) return;
    final next = !_paused;
    setState(() => _busy = true);
    try {
      await room.localParticipant?.setMicrophoneEnabled(!next);
      await Api.post('/api/broadcast/state', {..._creds, 'state': next ? 'paused' : 'resumed'});
      if (mounted) setState(() => _paused = next);
    } catch (e) {
      if (mounted) setState(() => _err = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pollCount() async {
    final id = _mid;
    if (id == null) return;
    try {
      final j = await Api.mosque(id);
      if (mounted) setState(() => _listeners = (j['listeners'] as num?)?.toInt() ?? 0);
    } catch (_) {}
  }

  Future<void> _disconnect({bool showMsg = false}) async {
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
        _paused = false;
        _reconnecting = false;
        if (showMsg) _info = tr('ended');
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
    if (ok != true) return;
    setState(() => _busy = true);
    // Tell the server first, so every listener sees "ended" before we hang up
    try {
      await Api.post('/api/broadcast/state', {..._creds, 'state': 'ended'});
    } catch (_) {}
    await _disconnect(showMsg: true);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _editSchedule() async {
    final ctl = TextEditingController(text: _schedule);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('editSchedule')),
        content: TextField(
          controller: ctl,
          maxLength: 300,
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(hintText: tr('scheduleHint'), border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kGreen),
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: Text(tr('save')),
          ),
        ],
      ),
    );
    if (v == null || v == _schedule) return;
    setState(() => _busy = true);
    try {
      await Api.post('/api/broadcast/schedule', {..._creds, 'text': v});
      if (mounted) {
        setState(() {
          _schedule = v;
          _info = tr('scheduleSaved');
        });
      }
    } catch (e) {
      if (mounted) setState(() => _err = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openQuestions() async {
    final id = _mid;
    final pin = _pin;
    if (id == null || pin == null) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => QuestionsScreen(mosqueId: id, pin: pin)));
    _reloadInfo();
  }

  @override
  void dispose() {
    _disconnect();
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
            children: [
              if (_mid == null) _loginCard() else if (_live) _liveCard() else _dashboardCard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _msgs() => Column(
        children: [
          if (_err.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_err, style: const TextStyle(color: kRed, fontSize: 15)),
            ),
          if (_info.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_info, style: const TextStyle(color: kGreen, fontSize: 15)),
            ),
        ],
      );

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
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'JMFM'),
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
              onSubmitted: (_) => _login(),
            ),
            const SizedBox(height: 18),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kGreen, padding: const EdgeInsets.all(16)),
              onPressed: _busy ? null : _login,
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text(tr('login'), style: const TextStyle(fontSize: 18)),
            ),
            _msgs(),
          ],
        ),
      ),
    );
  }

  Widget _dashboardCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            Text(_mid ?? '', textAlign: TextAlign.center, textDirection: TextDirection.ltr, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 18),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: kRed, padding: const EdgeInsets.all(18)),
              onPressed: _busy ? null : _goLive,
              icon: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.mic),
              label: Text(tr('goLive'), style: const TextStyle(fontSize: 20)),
            ),
            _msgs(),
            const SizedBox(height: 12),
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event, color: kGreen),
              title: Text(tr('schedule')),
              subtitle: Text(_schedule.isEmpty ? tr('noSchedule') : _schedule),
              trailing: IconButton(icon: const Icon(Icons.edit), tooltip: tr('editSchedule'), onPressed: _busy ? null : _editSchedule),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.question_answer, color: kGreen),
              title: Text(tr('questions')),
              trailing: Chip(label: Text('$_qCount')),
              onTap: _openQuestions,
            ),
            const SizedBox(height: 8),
            Text(tr('lockOk'), style: const TextStyle(color: Colors.grey)),
            TextButton(onPressed: _logout, child: Text(tr('logout'))),
          ],
        ),
      ),
    );
  }

  Widget _liveCard() {
    final color = _paused ? kOrange : kRed;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
              child: Text(_paused ? '⏸ ${tr('youArePaused')}' : '● ${tr('youAreLive')}',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            const SizedBox(height: 14),
            Text(_name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text(_elapsed,
                textDirection: TextDirection.ltr,
                style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold, fontFeatures: [FontFeature.tabularFigures()])),
            Text('$_listeners ${tr('listeners')}', style: const TextStyle(fontSize: 16, color: Colors.grey)),
            if (_reconnecting)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(tr('reconnecting'), style: const TextStyle(color: kOrange)),
              ),
            _msgs(),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: kOrange, padding: const EdgeInsets.all(16)),
                    onPressed: _busy ? null : _togglePause,
                    icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                    label: Text(_paused ? tr('resume') : tr('pause'), style: const TextStyle(fontSize: 17)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: kRed, padding: const EdgeInsets.all(16)),
                    onPressed: _busy ? null : _confirmEnd,
                    icon: const Icon(Icons.stop),
                    label: Text(tr('endLive'), style: const TextStyle(fontSize: 17)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.question_answer),
              label: Text(tr('questions')),
              onPressed: _openQuestions,
            ),
            const SizedBox(height: 12),
            Text(tr('lockOk'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
//  QUESTIONS (lecturer only)
// =====================================================================
class QuestionsScreen extends StatefulWidget {
  final String mosqueId;
  final String pin;
  const QuestionsScreen({super.key, required this.mosqueId, required this.pin});
  @override
  State<QuestionsScreen> createState() => _QuestionsState();
}

class _QuestionsState extends State<QuestionsScreen> with LangAware<QuestionsScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String _err = '';

  Map<String, dynamic> get _creds => {'mosqueId': widget.mosqueId, 'pin': widget.pin};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = '';
    });
    try {
      final j = await Api.post('/api/broadcast/questions', _creds);
      final list = j['questions'];
      _items = list is List ? list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : [];
    } catch (e) {
      _err = errText(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _delete(Map<String, dynamic> q) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(tr('deleteQuestion')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.post('/api/broadcast/questions/delete', {..._creds, 'id': q['id']});
      if (mounted) setState(() => _items.remove(q));
    } catch (e) {
      if (mounted) setState(() => _err = errText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kGreen,
        foregroundColor: Colors.white,
        title: Text(tr('questions')),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: tr('refresh'), onPressed: _load),
          langButton(),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
            if (_err.isNotEmpty) Text(_err, style: const TextStyle(color: kRed)),
            if (!_loading && _items.isEmpty && _err.isEmpty)
              Padding(padding: const EdgeInsets.all(30), child: Center(child: Text(tr('noQuestions')))),
            for (final q in _items)
              Card(
                child: ListTile(
                  title: Text(
                    (q['name'] ?? '').toString().isEmpty ? tr('anonymous') : q['name'].toString(),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(fmtWhen(q['at']?.toString()), style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 6),
                      SelectableText((q['text'] ?? '').toString(), style: const TextStyle(fontSize: 16, color: Colors.black87)),
                    ],
                  ),
                  trailing: IconButton(icon: const Icon(Icons.delete_outline), tooltip: tr('delete'), onPressed: () => _delete(q)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
