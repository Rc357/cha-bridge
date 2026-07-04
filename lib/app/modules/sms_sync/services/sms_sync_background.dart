import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'sms_sync_debug_log.dart';
import 'sms_sync_service.dart';

const String kBackgroundSmsSyncTask = 'background_sms_sync_task';
const String kBackgroundSmsSyncUniqueName = 'background_sms_sync_unique_name';
const _prefDefaultSyncInboxKey = 'default_sync_inbox_key';
const _prefSelectedSyncFallbackKey = 'selected_sync_key_fallback';
const _savedEmailKey = 'saved_login_email';
const _savedPasswordKey = 'saved_login_password';
const _secureStorage = FlutterSecureStorage();

@pragma('vm:entry-point')
void smsSyncBackgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    await SmsSyncDebugLog.append(
      'WorkManager task started: task=$task input=$inputData',
    );
    await Firebase.initializeApp();
    await SmsSyncDebugLog.append('WorkManager Firebase initialized.');

    if (task != kBackgroundSmsSyncTask) {
      await SmsSyncDebugLog.append('WorkManager ignored unknown task: $task');
      return true;
    }

    try {
      await _ensureAuthenticatedWithSavedCredentials();
      if (FirebaseAuth.instance.currentUser == null) {
        await SmsSyncDebugLog.append(
          'WorkManager sync skipped: no authenticated user in background.',
        );
        return false;
      }

      final service = SmsSyncService();
      final trigger = (inputData?['trigger'] as String?)?.trim() ?? '';
      final syncKey = await _resolveTargetSyncKey();
      int smsCount;
      int callCount;
      if (syncKey.isNotEmpty) {
        smsCount = await service.syncInboxByKey(
          syncKey,
          requestPermission: false,
          limit: 50,
        );
        callCount =
            trigger == 'sms_received'
                ? 0
                : await service.syncCallsByKey(
                  syncKey,
                  requestPermission: false,
                  limit: 50,
                );
      } else {
        smsCount = await service.syncAllInboxesForCurrentUser(
          requestPermission: false,
          limit: 50,
        );
        callCount =
            trigger == 'sms_received'
                ? 0
                : await service.syncAllCallsForCurrentUser(
                  requestPermission: false,
                  limit: 50,
                );
      }
      await SmsSyncDebugLog.append(
        'WorkManager sync finished: trigger=$trigger key=$syncKey sms=$smsCount calls=$callCount',
      );
      if (smsCount < 0 || callCount < 0) {
        await SmsSyncDebugLog.append(
          'WorkManager sync failed due to permission/session issue.',
        );
        return false;
      }
      return true;
    } catch (e) {
      await SmsSyncDebugLog.append('WorkManager sync exception: $e');
      return false;
    }
  });
}

Future<String> _resolveTargetSyncKey() async {
  final prefs = await SharedPreferences.getInstance();
  final selectedFallback =
      (prefs.getString(_prefSelectedSyncFallbackKey) ?? '').trim();
  if (selectedFallback.isNotEmpty) {
    return selectedFallback;
  }
  return (prefs.getString(_prefDefaultSyncInboxKey) ?? '').trim();
}

Future<void> _ensureAuthenticatedWithSavedCredentials() async {
  if (FirebaseAuth.instance.currentUser != null) {
    return;
  }
  try {
    final email = (await _secureStorage.read(key: _savedEmailKey))?.trim() ?? '';
    final password =
        (await _secureStorage.read(key: _savedPasswordKey))?.trim() ?? '';
    if (email.isEmpty || password.isEmpty) {
      await SmsSyncDebugLog.append(
        'Background auth restore skipped: no saved credentials.',
      );
      return;
    }
    await FirebaseAuth.instance.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
    await SmsSyncDebugLog.append('Background auth restored for WorkManager.');
  } catch (e) {
    await SmsSyncDebugLog.append('Background auth restore failed: $e');
  }
}

class SmsSyncBackgroundScheduler {
  static Future<void> setEnabled(
    bool enabled, {
    int intervalMinutes = 15,
  }) async {
    if (!Platform.isAndroid) {
      return;
    }

    final safeMinutes = intervalMinutes < 15 ? 15 : intervalMinutes;
    final frequency = Duration(minutes: safeMinutes);

    if (enabled) {
      await Workmanager().registerPeriodicTask(
        kBackgroundSmsSyncUniqueName,
        kBackgroundSmsSyncTask,
        frequency: frequency,
        initialDelay: frequency,
        existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
        constraints: Constraints(networkType: NetworkType.connected),
      );
    } else {
      await Workmanager().cancelByUniqueName(kBackgroundSmsSyncUniqueName);
    }
  }
}
