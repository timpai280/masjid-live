import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'api.dart';
import 'bg.dart';
import 'common.dart';
import 'strings.dart';

// =====================================================================
//  PAST SESSIONS (recordings kept on the server for a few days)
// =====================================================================
class SessionsScreen extends StatefulWidget {
  final String mosqueId;
  final String mosqueName;
  const SessionsScreen({super.key, required this.mosqueId, required this.mosqueName});
  @override
  State<SessionsScreen> createState() => _SessionsState();
}

class _SessionsState extends State<SessionsScreen> with LangAware<SessionsScreen> {
  final AudioPlayer _player = AudioPlayer();
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  bool _processing = false;
  int _keepDays = 14;
  String _err = '';
  String? _currentId;
  StreamSubscription<PlayerState>? _stateSub;

  @override
  void initState() {
    super.initState();
    _stateSub = _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _player.pause();
        _player.seek(Duration.zero);
        BgService.stop();
      }
      if (mounted) setState(() {});
    });
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = '';
    });
    try {
      final j = await Api.get('/api/mosques/${Uri.encodeComponent(widget.mosqueId)}/recordings');
      final list = j['recordings'];
      _items = list is List ? list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : [];
      _processing = j['processing'] == true;
      _keepDays = (j['keepDays'] as num?)?.toInt() ?? 14;
    } catch (e) {
      _err = errText(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  bool get _isPlaying => _player.playing && _player.processingState != ProcessingState.completed;

  Future<void> _toggle(Map<String, dynamic> item) async {
    final id = item['id'].toString();
    try {
      if (_currentId == id) {
        if (_isPlaying) {
          await _player.pause();
          await BgService.stop();
          return;
        }
      } else {
        await _player.stop();
        setState(() => _currentId = id);
        await _player.setUrl(Api.abs(item['url'].toString()));
      }
      await BgService.start(mic: false, title: widget.mosqueName, text: tr('recording'));
      unawaited(_player.play());
    } catch (e) {
      if (mounted) setState(() => _err = errText(e));
    }
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _player.dispose();
    BgService.stop();
    super.dispose();
  }

  Widget _progress() {
    return StreamBuilder<Duration>(
      stream: _player.positionStream,
      builder: (context, snap) {
        final pos = snap.data ?? Duration.zero;
        final dur = _player.duration ?? Duration.zero;
        final max = dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
        final value = pos.inMilliseconds.toDouble().clamp(0.0, max);
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Column(
            children: [
              Slider(
                value: value,
                max: max,
                activeColor: kGreen,
                onChanged: (v) => _player.seek(Duration(milliseconds: v.toInt())),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(fmtClock(pos), textDirection: TextDirection.ltr),
                  Text(fmtClock(dur), textDirection: TextDirection.ltr),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kGreen,
        foregroundColor: Colors.white,
        title: Text(tr('pastSessions')),
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
            Text(widget.mosqueName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text(tr('keptFor').replaceAll('{n}', '$_keepDays'), style: const TextStyle(color: Colors.grey)),
            if (_processing)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(tr('processing'), style: const TextStyle(color: kOrange)),
              ),
            const SizedBox(height: 12),
            if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
            if (_err.isNotEmpty) Text(_err, style: const TextStyle(color: kRed)),
            if (!_loading && _items.isEmpty && _err.isEmpty)
              Padding(padding: const EdgeInsets.all(30), child: Center(child: Text(tr('noRecordings')))),
            for (final r in _items)
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: IconButton.filled(
                        style: IconButton.styleFrom(backgroundColor: kGreen),
                        icon: Icon(_currentId == r['id'].toString() && _isPlaying ? Icons.pause : Icons.play_arrow),
                        onPressed: () => _toggle(r),
                      ),
                      title: Text(fmtWhen(r['startedAt']?.toString())),
                      subtitle: Text(fmtDuration((r['durationSec'] as num?)?.toInt() ?? 0)),
                      onTap: () => _toggle(r),
                    ),
                    if (_currentId == r['id'].toString()) _progress(),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
