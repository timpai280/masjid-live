import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// "Tafseer is LIVE" notifications (Firebase Cloud Messaging).
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

  /// Mosque ID if the app was opened by tapping a LIVE notification.
  static Future<String?> initialLiveMosque() async {
    if (!ready) return null;
    try {
      final m = await FirebaseMessaging.instance.getInitialMessage();
      final id = m?.data['mosqueId'];
      return id is String && id.isNotEmpty ? id : null;
    } catch (_) {
      return null;
    }
  }

  static StreamSubscription<RemoteMessage>? onOpened(void Function(String mosqueId) cb) {
    if (!ready) return null;
    return FirebaseMessaging.onMessageOpenedApp.listen((m) {
      final id = m.data['mosqueId'];
      if (id is String && id.isNotEmpty) cb(id);
    });
  }
}
