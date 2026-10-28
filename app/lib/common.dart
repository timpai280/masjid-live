import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'strings.dart';

const kGreen = Color(0xFF0F7B5F);
const kRed = Color(0xFFD93025);
const kOrange = Color(0xFFE37400);
late SharedPreferences prefs;

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

/// Status sent by the server in the room metadata: {"status":"live|paused|ended|offline", ...}
String parseStatus(String? metadata) {
  if (metadata == null || metadata.isEmpty) return '';
  try {
    final j = jsonDecode(metadata);
    if (j is Map && j['status'] is String) return j['status'] as String;
  } catch (_) {}
  return '';
}

bool isOnAir(String s) => s == 'live' || s == 'paused';

Widget statusBadge(String s) {
  final on = isOnAir(s);
  final label = switch (s) {
    'live' => '● ${tr('live')}',
    'paused' => '⏸ ${tr('paused')}',
    'ended' => tr('endedShort'),
    _ => tr('offline'),
  };
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
    decoration: BoxDecoration(
      color: s == 'live' ? kRed : (s == 'paused' ? kOrange : Colors.grey.shade300),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(label, style: TextStyle(color: on ? Colors.white : Colors.black54, fontWeight: FontWeight.bold)),
  );
}

Widget scheduleCard(String text) => Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFFEEF6F2), borderRadius: BorderRadius.circular(12)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.event, color: kGreen),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('schedule'), style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(text, style: const TextStyle(fontSize: 15)),
              ],
            ),
          ),
        ],
      ),
    );

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "Wed, 4 Nov 2026 · 7:05 PM" in the phone's local time
String fmtWhen(String? iso) {
  final d = DateTime.tryParse(iso ?? '')?.toLocal();
  if (d == null) return '';
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  final ap = d.hour < 12 ? 'AM' : 'PM';
  return '${_days[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]} ${d.year} · $h:$m $ap';
}

String fmtDuration(int sec) {
  final mins = (sec / 60).round();
  if (mins < 60) return '$mins min';
  return '${mins ~/ 60} h ${(mins % 60).toString().padLeft(2, '0')} min';
}

String fmtClock(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// Listener sends a question to the lecturer (name optional).
Future<void> askQuestion(BuildContext context, String mosqueId) async {
  final nameCtl = TextEditingController(text: prefs.getString('qName') ?? '');
  final textCtl = TextEditingController();
  var sending = false;
  var err = '';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text(tr('askQuestion')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr('askHint'), style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtl,
                maxLength: 40,
                decoration: InputDecoration(labelText: tr('yourName'), border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: textCtl,
                maxLength: 500,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(labelText: tr('yourQuestion'), border: const OutlineInputBorder()),
              ),
              if (err.isNotEmpty) Text(err, style: const TextStyle(color: kRed)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: sending ? null : () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kGreen),
            onPressed: sending
                ? null
                : () async {
                    final t = textCtl.text.trim();
                    if (t.length < 2) {
                      setD(() => err = tr('err_empty'));
                      return;
                    }
                    setD(() {
                      sending = true;
                      err = '';
                    });
                    try {
                      await Api.post('/api/questions', {'mosqueId': mosqueId, 'name': nameCtl.text.trim(), 'text': t});
                      await prefs.setString('qName', nameCtl.text.trim());
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    } catch (e) {
                      setD(() {
                        sending = false;
                        err = errText(e);
                      });
                    }
                  },
            child: Text(tr('send')),
          ),
        ],
      ),
    ),
  );
  if (ok == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('questionSent'))));
  }
}
