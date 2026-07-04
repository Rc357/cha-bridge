import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sms_sync_debug_log.dart';
import 'sms_sync_service.dart';

const _relayServiceId = 1010;
const _savedEmailKey = 'saved_login_email';
const _savedPasswordKey = 'saved_login_password';
const _secureStorage = FlutterSecureStorage();

@pragma('vm:entry-point')
void smsSyncRelayStartCallback() {
  FlutterForegroundTask.setTaskHandler(SmsSyncRelayTaskHandler());
}

class SmsSyncRelayTaskHandler extends TaskHandler {
  static const _prefDefaultSyncInboxKey = 'default_sync_inbox_key';
  static const _prefCurrentInboxFallbackKey = 'selected_sync_key_fallback';

  bool _isSyncing = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _runSync();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _runSync();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  Future<void> _runSync() async {
    if (_isSyncing) {
      return;
    }
    _isSyncing = true;
    try {
      await Firebase.initializeApp();
      await _ensureAuthenticatedWithSavedCredentials();
      final authReady = await _waitForSignedInUser();
      if (!authReady) {
        await SmsSyncDebugLog.append('Relay sync skipped: auth session not ready.');
        await FlutterForegroundTask.updateService(
          notificationTitle: 'Cha Bridge relay active',
          notificationText: 'Sync failed: account session not ready.',
        );
        return;
      }
      final syncKey = await _resolveSyncKey();
      if (syncKey.isEmpty) {
        await SmsSyncDebugLog.append('Relay sync skipped: no target inbox key.');
        await FlutterForegroundTask.updateService(
          notificationTitle: 'Cha Bridge relay active',
          notificationText: 'No default sync inbox selected.',
        );
        return;
      }

      final service = SmsSyncService();
      final smsCount = await service.syncInboxByKey(
        syncKey,
        requestPermission: false,
      );
      final callCount = await service.syncCallsByKey(
        syncKey,
        requestPermission: false,
      );

      if (smsCount < 0 || callCount < 0) {
        await SmsSyncDebugLog.append(
          'Relay sync failed: key=$syncKey sms=$smsCount calls=$callCount',
        );
        await FlutterForegroundTask.updateService(
          notificationTitle: 'Cha Bridge relay active',
          notificationText: 'Sync failed: permission/session issue.',
        );
        return;
      }

      await SmsSyncDebugLog.append(
        'Relay sync success: key=$syncKey sms=$smsCount calls=$callCount',
      );
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Cha Bridge relay active',
        notificationText: 'Last sync: SMS $smsCount, Calls $callCount',
      );
    } catch (e) {
      await SmsSyncDebugLog.append('Relay sync error: $e');
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Cha Bridge relay active',
        notificationText: 'Sync error: $e',
      );
    } finally {
      _isSyncing = false;
    }
  }

  Future<String> _resolveSyncKey() async {
    final prefs = await SharedPreferences.getInstance();
    final selectedFallback =
        (prefs.getString(_prefCurrentInboxFallbackKey) ?? '').trim();
    if (selectedFallback.isNotEmpty) {
      return selectedFallback;
    }
    final defaultKey = (prefs.getString(_prefDefaultSyncInboxKey) ?? '').trim();
    if (defaultKey.isNotEmpty) {
      return defaultKey;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return '';
    }

    try {
      final inboxes =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .collection('inboxes')
              .where('isDeleted', isEqualTo: false)
              .limit(1)
              .get();
      if (inboxes.docs.isNotEmpty) {
        final doc = inboxes.docs.first;
        final firstKey = (doc.data()['syncKey'] as String?)?.trim() ?? doc.id;
        await prefs.setString(_prefCurrentInboxFallbackKey, firstKey);
        return firstKey;
      }
    } catch (_) {}

    return '';
  }

  Future<bool> _waitForSignedInUser() async {
    if (FirebaseAuth.instance.currentUser != null) {
      return true;
    }
    try {
      final user = await FirebaseAuth.instance
          .authStateChanges()
          .firstWhere((user) => user != null)
          .timeout(const Duration(seconds: 20));
      return user != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> _ensureAuthenticatedWithSavedCredentials() async {
    if (FirebaseAuth.instance.currentUser != null) {
      return;
    }
    try {
      final email =
          (await _secureStorage.read(key: _savedEmailKey))?.trim() ?? '';
      final password =
          (await _secureStorage.read(key: _savedPasswordKey))?.trim() ?? '';
      if (email.isEmpty || password.isEmpty) {
        return;
      }
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      await SmsSyncDebugLog.append('Relay background auth restored.');
    } catch (_) {
      await SmsSyncDebugLog.append('Relay background auth restore failed.');
      // Ignore; wait function handles timeout path.
    }
  }
}

class SmsSyncRelayService {
  static int? _configuredIntervalMinutes;

  static Future<bool> isRunning() async {
    if (kIsWeb || !Platform.isAndroid) {
      return false;
    }
    return FlutterForegroundTask.isRunningService;
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (kIsWeb || !Platform.isAndroid) {
      return true;
    }
    return FlutterForegroundTask.isIgnoringBatteryOptimizations;
  }

  static Future<bool> requestIgnoreBatteryOptimization() async {
    if (kIsWeb || !Platform.isAndroid) {
      return true;
    }
    return FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }

  static Future<bool> openIgnoreBatteryOptimizationSettings() async {
    if (kIsWeb || !Platform.isAndroid) {
      return false;
    }
    return FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
  }

  static Future<void> _ensureInitialized(int intervalMinutes) async {
    if (_configuredIntervalMinutes == intervalMinutes) {
      return;
    }

    final intervalMs = intervalMinutes * 60 * 1000;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'cha_bridge_relay',
        channelName: 'Cha Bridge Relay',
        channelDescription: 'Keeps SMS and call sync active for OTP relay.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(intervalMs),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _configuredIntervalMinutes = intervalMinutes;
  }

  static Future<bool> setEnabled(
    bool enabled, {
    int intervalMinutes = 1,
  }) async {
    if (kIsWeb || !Platform.isAndroid) {
      return false;
    }

    if (!enabled) {
      if (await isRunning()) {
        await FlutterForegroundTask.stopService();
      }
      await SmsSyncDebugLog.append('Relay disabled.');
      return false;
    }

    final beforePermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (beforePermission != NotificationPermission.granted) {
      await SmsSyncDebugLog.append(
        'Relay needs notification permission. Requesting...',
      );
      await FlutterForegroundTask.requestNotificationPermission();
    }
    final afterPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (afterPermission != NotificationPermission.granted) {
      await SmsSyncDebugLog.append(
        'Relay start blocked: notification permission denied.',
      );
      throw StateError('Notification permission denied for background relay.');
    }

    if (!await isIgnoringBatteryOptimizations()) {
      await requestIgnoreBatteryOptimization();
      await SmsSyncDebugLog.append('Requested ignore battery optimization.');
    }

    await _ensureInitialized(intervalMinutes.clamp(1, 14));
    if (await isRunning()) {
      await FlutterForegroundTask.restartService();
      await SmsSyncDebugLog.append(
        'Relay restarted (${intervalMinutes.clamp(1, 14)} min interval).',
      );
      return await isRunning();
    }

    await FlutterForegroundTask.startService(
      serviceId: _relayServiceId,
      serviceTypes: [ForegroundServiceTypes.dataSync],
      notificationTitle: 'Cha Bridge relay active',
      notificationText: 'Syncing SMS/Calls in background',
      callback: smsSyncRelayStartCallback,
    );
    final running = await isRunning();
    await SmsSyncDebugLog.append(
      running
          ? 'Relay started (${intervalMinutes.clamp(1, 14)} min interval).'
          : 'Relay failed to start (service not running).',
    );
    if (!running) {
      throw StateError('Foreground relay service failed to start.');
    }
    return running;
  }
}
