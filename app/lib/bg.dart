import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the app running with the screen locked (Android "foreground service"
/// with a small notification). mic=true for the lecturer, false for listeners.
/// The native side is in android_overlay/.../LiveService.kt
class BgService {
  static const _channel = MethodChannel('masjid_live/bg');

  static Future<void> start({required bool mic, required String title, required String text}) async {
    try {
      await _channel.invokeMethod('start', {'mic': mic, 'title': title, 'text': text});
    } catch (e) {
      debugPrint('BgService.start failed: $e');
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      debugPrint('BgService.stop failed: $e');
    }
  }
}
