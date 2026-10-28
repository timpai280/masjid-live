import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// A notification the user tapped: which mosque, and what kind ('live' or 'schedule').
class PushOpen {
  final String mosqueId;
  final String type;
  const PushOpen(this.mosqueId, this.type);
}

PushOpen? _parse(RemoteMessage? m) {
  final id = m?.data['mosqueId'];
  if (id is! String || id.isEmpty) return null;
  final type = m?.data['type'];
  return PushOpen(id, type is String ? type : 'live');
}

/// "Lesson is LIVE" / "Schedule updated" notifications (Firebase Cloud Messaging).
/// Each mosque is a topic: mosque_<ID>. If Firebase is not set up yet
/// (no google-services.json at build time) everything here quietly does nothing.
class Push {
  static bool ready = false;

  static Future<void> init() async {
    try {
      await Firebase.initializeApp();
      ready = true;
    } catch (e) {
      debugPrint('Push disabled: $e');
    }
  }

  static Future<void> follow(String? oldId, String newId) async {
    if (!ready) return;
    try {
      if (oldId != null && oldId.isNotEmpty && oldId != newId) {
        await FirebaseMessaging.instance.unsubscribeFromTopic('mosque_$oldId');
      }
      await FirebaseMessaging.instance.subscribeToTopic('mosque_$newId');
    } catch (e) {
      debugPrint('subscribe failed: $e');
    }
  }

  static Future<void> unfollow(String id) async {
    if (!ready) return;
    try {
      await FirebaseMessaging.instance.unsubscribeFromTopic('mosque_$id');
    } catch (_) {}
  }

  /// Set if the app was opened by tapping a notification.
  static Future<PushOpen?> initialOpen() async {
    if (!ready) return null;
    try {
      return _parse(await FirebaseMessaging.instance.getInitialMessage());
    } catch (_) {
      return null;
    }
  }

  static StreamSubscription<RemoteMessage>? onOpened(void Function(PushOpen open) cb) {
    if (!ready) return null;
    return FirebaseMessaging.onMessageOpenedApp.listen((m) {
      final o = _parse(m);
      if (o != null) cb(o);
    });
  }
}
