import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/sms_sync_background.dart';
import '../services/sms_sync_debug_log.dart';
import '../services/sms_sync_incoming_trigger.dart';
import '../services/sms_sync_relay_service.dart';
import '../services/sms_sync_service.dart';

class SmsSyncController extends GetxController {
  SmsSyncController({SmsSyncService? syncService})
    : _syncService = syncService ?? SmsSyncService();

  static const _prefAutoSyncOnResume = 'auto_sync_on_resume';
  static const _prefDefaultSyncInboxKey = 'default_sync_inbox_key';
  static const _prefDefaultSyncInboxName = 'default_sync_inbox_name';
  static const _prefSelectedSyncFallbackKey = 'selected_sync_key_fallback';
  static const _prefPeriodicSync = 'periodic_sync_enabled';
  static const _prefPeriodicSyncMinutes = 'periodic_sync_minutes';
  static const _prefBackgroundSync = 'background_sync_enabled';
  static const _prefBackgroundSyncMinutes = 'background_sync_minutes';
  static const _prefBiometricUnlock = 'biometric_unlock_enabled';

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final SmsSyncService _syncService;

  final isSyncing = false.obs;
  final isPulling = false.obs;
  final isDeletingInbox = false.obs;
  final status = 'Ready'.obs;
  final selectedSyncKey = ''.obs;
  final selectedInboxName = ''.obs;
  final defaultSyncInboxKey = ''.obs;
  final defaultSyncInboxName = ''.obs;
  final _permissionRetryByInbox = <String, int>{};
  bool _permissionRetryInFlight = false;
  bool _initialPermissionsRequested = false;

  final autoSyncOnResume = false.obs;
  final periodicSyncEnabled = false.obs;
  final periodicSyncIntervalMinutes = 15.obs;
  final backgroundSyncEnabled = false.obs;
  final backgroundSyncIntervalMinutes = 15.obs;
  final biometricUnlockEnabled = false.obs;
  final batteryOptimizationIgnored = false.obs;

  final LocalAuthentication _localAuth = LocalAuthentication();

  Timer? _periodicTimer;

  CollectionReference<Map<String, dynamic>> _userInboxesRef(String uid) {
    return _firestore.collection('users').doc(uid).collection('inboxes');
  }

  @override
  void onInit() {
    super.onInit();
    unawaited(_loadSettings());
    unawaited(_syncService.initializeCrypto());
  }

  @override
  void onClose() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
    super.onClose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final hasAutoSyncPref = prefs.containsKey(_prefAutoSyncOnResume);
    autoSyncOnResume.value =
        hasAutoSyncPref ? (prefs.getBool(_prefAutoSyncOnResume) ?? false) : false;
    if (!hasAutoSyncPref) {
      await prefs.setBool(_prefAutoSyncOnResume, false);
    }
    defaultSyncInboxKey.value = prefs.getString(_prefDefaultSyncInboxKey) ?? '';
    defaultSyncInboxName.value =
        prefs.getString(_prefDefaultSyncInboxName) ?? '';
    periodicSyncEnabled.value = prefs.getBool(_prefPeriodicSync) ?? false;
    periodicSyncIntervalMinutes.value =
        (prefs.getInt(_prefPeriodicSyncMinutes) ?? 15).clamp(1, 180);
    backgroundSyncEnabled.value = prefs.getBool(_prefBackgroundSync) ?? false;
    backgroundSyncIntervalMinutes.value =
        (prefs.getInt(_prefBackgroundSyncMinutes) ?? 15).clamp(1, 180);
    biometricUnlockEnabled.value = prefs.getBool(_prefBiometricUnlock) ?? false;

    _configurePeriodicTimer();
    try {
      await _applyBackgroundSyncMode();
    } catch (_) {
      // Keep app usable; status gets updated when user toggles background sync.
    }
    await refreshBatteryOptimizationStatus(silent: true);
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> inboxesStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const Stream.empty();
    }

    return _userInboxesRef(uid).snapshots();
  }

  Future<void> createInbox(String inboxName, {String? password}) async {
    final name = inboxName.trim();
    if (name.isEmpty) {
      status.value = 'Inbox name is required.';
      return;
    }
    final rawPassword = (password ?? '').trim();
    final hasPassword = rawPassword.isNotEmpty;
    final passwordHash = hasPassword ? _hashPassword(rawPassword) : null;

    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid;
    if (uid == null) {
      status.value = 'Not signed in. Please sign in again.';
      return;
    }

    try {
      // First write after login can fail with stale auth token in some sessions.
      await user!.getIdToken(true);

      final syncKey = _firestore.collection('sync_keys').doc().id;
      final batch = _firestore.batch();
      final userInboxRef = _userInboxesRef(uid).doc(syncKey);
      final syncKeyRef = _firestore.collection('sync_keys').doc(syncKey);

      final userInboxData = <String, dynamic>{
        'name': name,
        'syncKey': syncKey,
        'isDeleted': false,
        'deletedAt': null,
        'createdAt': FieldValue.serverTimestamp(),
      };
      if (hasPassword) {
        userInboxData['isPasswordProtected'] = true;
        userInboxData['passwordHash'] = passwordHash;
      }

      final syncKeyData = <String, dynamic>{
        'ownerUid': uid,
        'name': name,
        'isDeleted': false,
        'deletedAt': null,
        'createdAt': FieldValue.serverTimestamp(),
      };

      batch.set(userInboxRef, userInboxData);
      batch.set(syncKeyRef, syncKeyData);

      await batch.commit();

      selectedSyncKey.value = syncKey;
      selectedInboxName.value = name;
      if (defaultSyncInboxKey.value.isEmpty) {
        await setDefaultSyncInbox(syncKey: syncKey, name: name, silent: true);
      }
      status.value = 'Inbox created.';
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        status.value =
            'Create inbox failed [permission-denied]. Check deployed Firestore rules for users/{uid}/inboxes and sync_keys.';
        return;
      }
      status.value = 'Create inbox failed [${e.code}]: ${e.message ?? ''}';
    } catch (e) {
      status.value = 'Create inbox failed: $e';
    }
  }

  void selectInbox(String syncKey, String name) {
    selectedSyncKey.value = syncKey;
    selectedInboxName.value = name;
    _permissionRetryByInbox[syncKey] = 0;
    unawaited(_persistSelectedSyncFallback(syncKey));
    if (defaultSyncInboxKey.value.isEmpty) {
      unawaited(setDefaultSyncInbox(syncKey: syncKey, name: name, silent: true));
    }
    status.value = 'Selected inbox: $name';
  }

  void clearSelectedInbox() {
    selectedSyncKey.value = '';
    selectedInboxName.value = '';
  }

  bool isDefaultSyncInbox(String syncKey) {
    return defaultSyncInboxKey.value == syncKey;
  }

  Future<void> setDefaultSyncInbox({
    required String syncKey,
    required String name,
    bool silent = false,
  }) async {
    defaultSyncInboxKey.value = syncKey;
    defaultSyncInboxName.value = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefDefaultSyncInboxKey, syncKey);
    await prefs.setString(_prefDefaultSyncInboxName, name);
    if (!silent) {
      status.value = 'Default sync inbox set to "$name".';
    }
  }

  Future<void> clearDefaultSyncInbox({bool silent = false}) async {
    defaultSyncInboxKey.value = '';
    defaultSyncInboxName.value = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefDefaultSyncInboxKey);
    await prefs.remove(_prefDefaultSyncInboxName);
    if (!silent) {
      status.value = 'Default sync inbox cleared.';
    }
  }

  Future<void> _persistSelectedSyncFallback(String syncKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefSelectedSyncFallbackKey, syncKey);
  }

  Future<void> retryAfterPermissionDenied() async {
    if (_permissionRetryInFlight) {
      return;
    }

    final key = selectedSyncKey.value.trim();
    if (key.isEmpty) {
      return;
    }

    final tries = _permissionRetryByInbox[key] ?? 0;
    if (tries >= 2) {
      status.value = 'Permission denied for this inbox. Try reopening it.';
      return;
    }

    _permissionRetryInFlight = true;
    _permissionRetryByInbox[key] = tries + 1;
    final name = selectedInboxName.value;

    selectedSyncKey.value = '';
    await Future.delayed(const Duration(milliseconds: 450));

    if (selectedSyncKey.value.isEmpty) {
      selectedSyncKey.value = key;
      selectedInboxName.value = name;
      status.value = 'Retrying inbox access...';
    }

    _permissionRetryInFlight = false;
  }

  bool isInboxProtected(Map<String, dynamic> data) {
    return data['isPasswordProtected'] == true &&
        ((data['passwordHash'] as String?)?.isNotEmpty ?? false);
  }

  bool isInboxDeleted(Map<String, dynamic> data) {
    return data['isDeleted'] == true;
  }

  Future<bool> selectInboxWithPassword({
    required String syncKey,
    required String name,
    required String? expectedPasswordHash,
    String password = '',
  }) async {
    final hash = expectedPasswordHash?.trim() ?? '';
    if (hash.isEmpty) {
      selectInbox(syncKey, name);
      return true;
    }

    if (biometricUnlockEnabled.value) {
      final unlocked = await _authenticateWithBiometric(
        reason: 'Use fingerprint to unlock "$name"',
      );
      if (unlocked) {
        selectInbox(syncKey, name);
        status.value = 'Unlocked inbox with biometrics: $name';
        return true;
      }
    }

    if (password.trim().isEmpty) {
      status.value = 'Password required for "$name".';
      return false;
    }

    if (_hashPassword(password.trim()) != hash) {
      status.value = 'Incorrect password for "$name".';
      return false;
    }

    selectInbox(syncKey, name);
    status.value = 'Unlocked inbox: $name';
    return true;
  }

  Future<String?> getInboxPasswordHash(String syncKey) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return null;
    }
    final doc = await _userInboxesRef(uid).doc(syncKey).get();
    if (!doc.exists) {
      return null;
    }
    return doc.data()?['passwordHash'] as String?;
  }

  Future<bool> canAccessLockedInbox({
    required String name,
    required String? expectedPasswordHash,
    String password = '',
  }) async {
    final hash = expectedPasswordHash?.trim() ?? '';
    if (hash.isEmpty) {
      return true;
    }

    if (biometricUnlockEnabled.value) {
      final unlocked = await _authenticateWithBiometric(
        reason: 'Use fingerprint to unlock "$name"',
      );
      if (unlocked) {
        status.value = 'Unlocked with biometrics: $name';
        return true;
      }
    }

    if (password.trim().isEmpty) {
      return false;
    }

    return _hashPassword(password.trim()) == hash;
  }

  Future<bool> setInboxPassword({
    required String syncKey,
    required String password,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      status.value = 'Not signed in. Please sign in again.';
      return false;
    }

    final rawPassword = password.trim();
    if (rawPassword.isEmpty) {
      status.value = 'Password is required.';
      return false;
    }

    try {
      await _userInboxesRef(uid).doc(syncKey).set({
        'isPasswordProtected': true,
        'passwordHash': _hashPassword(rawPassword),
      }, SetOptions(merge: true));
      status.value = 'Inbox password updated.';
      return true;
    } on FirebaseException catch (e) {
      status.value = 'Failed to update password [${e.code}]: ${e.message ?? ''}';
      return false;
    } catch (e) {
      status.value = 'Failed to update password: $e';
      return false;
    }
  }

  Future<void> deleteInbox({
    required String syncKey,
    required String name,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      status.value = 'Not signed in. Please sign in again.';
      return;
    }

    if (syncKey.trim().isEmpty) {
      status.value = 'Invalid inbox key.';
      return;
    }

    isDeletingInbox.value = true;
    try {
      status.value = 'Deleting inbox "$name"...';

      final deletingCurrentlySelected = selectedSyncKey.value == syncKey;
      final deletingDefaultSync = defaultSyncInboxKey.value == syncKey;
      if (deletingCurrentlySelected) {
        // Stop active message/call streams before docs are removed to avoid
        // transient permission-denied flashes during delete.
        selectedSyncKey.value = '';
        selectedInboxName.value = '';
      }

      final syncDocRef = _firestore.collection('sync_keys').doc(syncKey);
      final syncDoc = await syncDocRef.get();
      if (syncDoc.exists) {
        final ownerUid = syncDoc.data()?['ownerUid'] as String?;
        if (ownerUid != uid) {
          status.value = 'You are not allowed to delete this inbox.';
          return;
        }
      }

      await syncDocRef.set({
        'isDeleted': true,
        'deletedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await _userInboxesRef(uid).doc(syncKey).set({
        'isDeleted': true,
        'deletedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (deletingDefaultSync) {
        await clearDefaultSyncInbox(silent: true);
      }
      status.value = 'Inbox "$name" deleted.';
    } on FirebaseException catch (e) {
      status.value = 'Delete inbox failed [${e.code}]: ${e.message ?? ''}';
    } catch (e) {
      status.value = 'Delete inbox failed: $e';
    } finally {
      isDeletingInbox.value = false;
    }
  }

  Future<void> setAutoSyncOnResume(bool enabled) async {
    autoSyncOnResume.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefAutoSyncOnResume, enabled);
  }

  Future<void> setPeriodicSyncEnabled(bool enabled) async {
    periodicSyncEnabled.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefPeriodicSync, enabled);
    _configurePeriodicTimer();

    status.value =
        enabled
            ? 'Periodic call-log sync enabled (every ${periodicSyncIntervalMinutes.value} min while app is open). Incoming SMS uses the native receiver.'
            : 'Periodic auto-sync disabled.';
  }

  Future<void> setPeriodicSyncIntervalMinutes(int minutes) async {
    final safe = minutes.clamp(1, 180);
    periodicSyncIntervalMinutes.value = safe;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefPeriodicSyncMinutes, safe);
    _configurePeriodicTimer();
    status.value = 'Foreground call-log sync interval set to every $safe minutes.';
  }

  Future<void> setBackgroundSyncEnabled(bool enabled) async {
    backgroundSyncEnabled.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefBackgroundSync, enabled);
    try {
      await _applyBackgroundSyncMode();
    } catch (e) {
      status.value = 'Background sync start failed: $e';
      return;
    }
    await refreshBatteryOptimizationStatus(silent: true);

    if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) {
      status.value = 'Background sync is available on Android only.';
      return;
    }

    if (!enabled) {
      status.value = 'Background sync disabled.';
      return;
    }
    if (backgroundSyncIntervalMinutes.value < 15) {
      final running = await SmsSyncRelayService.isRunning();
      if (!running) {
        status.value =
            'Background relay failed to run. Allow notifications and set battery to Unrestricted.';
        return;
      }
      status.value =
          'Background relay enabled (foreground service, every ${backgroundSyncIntervalMinutes.value} min).';
    } else {
      status.value =
          'Background sync enabled (WorkManager, every ${backgroundSyncIntervalMinutes.value} min).';
    }
  }

  Future<void> setBackgroundSyncIntervalMinutes(int minutes) async {
    final safe = minutes.clamp(1, 180);
    backgroundSyncIntervalMinutes.value = safe;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefBackgroundSyncMinutes, safe);

    if (backgroundSyncEnabled.value) {
      try {
        await _applyBackgroundSyncMode();
      } catch (e) {
        status.value = 'Background sync update failed: $e';
        return;
      }
    }

    if (safe < 15) {
      status.value = 'Background relay interval set to every $safe minutes.';
    } else {
      status.value = 'Background sync interval set to every $safe minutes.';
    }
  }

  Future<void> setBiometricUnlockEnabled(bool enabled) async {
    if (enabled) {
      final supported = await isBiometricSupported();
      if (!supported) {
        status.value = 'Biometric unlock is not available on this device.';
        biometricUnlockEnabled.value = false;
        return;
      }
    }

    biometricUnlockEnabled.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefBiometricUnlock, enabled);
    status.value =
        enabled
            ? 'Biometric unlock enabled for locked inboxes.'
            : 'Biometric unlock disabled.';
  }

  Future<void> refreshBatteryOptimizationStatus({bool silent = false}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      batteryOptimizationIgnored.value = true;
      if (!silent) {
        status.value = 'Battery optimization controls are Android only.';
      }
      return;
    }

    try {
      final ignored = await SmsSyncRelayService.isIgnoringBatteryOptimizations();
      batteryOptimizationIgnored.value = ignored;
      if (!silent) {
        status.value =
            ignored
                ? 'Battery optimization is disabled for Cha Bridge.'
                : 'Battery optimization is ON. Background sync may stop.';
      }
    } catch (e) {
      if (!silent) {
        status.value = 'Unable to read battery optimization status: $e';
      }
    }
  }

  Future<void> requestBatteryOptimizationExemption() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      status.value = 'Battery optimization controls are Android only.';
      return;
    }

    try {
      final alreadyIgnored =
          await SmsSyncRelayService.isIgnoringBatteryOptimizations();
      if (alreadyIgnored) {
        batteryOptimizationIgnored.value = true;
        status.value = 'Battery optimization is already disabled.';
        return;
      }

      await SmsSyncRelayService.requestIgnoreBatteryOptimization();
      await refreshBatteryOptimizationStatus(silent: true);

      if (batteryOptimizationIgnored.value) {
        status.value = 'Battery optimization disabled for Cha Bridge.';
      } else {
        status.value =
            'Please allow "Unrestricted" battery for Cha Bridge in system settings.';
      }
    } catch (e) {
      status.value = 'Failed to request battery optimization exception: $e';
    }
  }

  Future<void> openBatteryOptimizationSettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      status.value = 'Battery optimization controls are Android only.';
      return;
    }

    try {
      final opened =
          await SmsSyncRelayService.openIgnoreBatteryOptimizationSettings();
      if (!opened) {
        status.value = 'Could not open battery optimization settings.';
      } else {
        status.value = 'Opened battery optimization settings.';
      }
    } catch (e) {
      status.value = 'Failed to open battery optimization settings: $e';
    }
  }

  Future<bool> isBiometricSupported() async {
    if (kIsWeb) {
      return false;
    }
    try {
      final isSupported = await _localAuth.isDeviceSupported();
      final canCheckBiometrics = await _localAuth.canCheckBiometrics;
      return isSupported && canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  void handleAppResumed() {
    if (!autoSyncOnResume.value) {
      return;
    }
    unawaited(syncAll(trigger: 'resume'));
  }

  void handleScreenOpened() {
    if (!autoSyncOnResume.value) {
      return;
    }
    unawaited(syncAll(trigger: 'open'));
  }

  Future<void> requestSyncPermissionsOnLogin() async {
    if (_initialPermissionsRequested) {
      return;
    }
    _initialPermissionsRequested = true;

    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    final smsGranted = await _syncService.ensureSmsPermission(
      requestIfNeeded: true,
    );
    final callGranted = await _syncService.ensureCallPermission(
      requestIfNeeded: true,
    );
    if (smsGranted) {
      await initializeIncomingSmsTrigger();
    }

    if (smsGranted && callGranted) {
      status.value = 'SMS and call permissions granted.';
    } else if (smsGranted) {
      status.value = 'SMS permission granted. Enable Call Log permission for call sync.';
    } else {
      status.value = 'Please allow SMS permission to auto-sync incoming messages.';
    }
  }

  void _configurePeriodicTimer() {
    _periodicTimer?.cancel();
    _periodicTimer = null;

    if (!periodicSyncEnabled.value) {
      return;
    }

    _periodicTimer = Timer.periodic(
      Duration(minutes: periodicSyncIntervalMinutes.value),
      (_) {
      unawaited(syncAll(trigger: 'periodic'));
      },
    );
  }

  Future<void> _applyBackgroundSyncMode() async {
    if (!backgroundSyncEnabled.value) {
      await SmsSyncBackgroundScheduler.setEnabled(false);
      await SmsSyncRelayService.setEnabled(false);
      return;
    }

    final interval = backgroundSyncIntervalMinutes.value;
    if (interval < 15) {
      await SmsSyncBackgroundScheduler.setEnabled(false);
      await SmsSyncRelayService.setEnabled(true, intervalMinutes: interval);
      return;
    }

    await SmsSyncRelayService.setEnabled(false);
    await SmsSyncBackgroundScheduler.setEnabled(
      true,
      intervalMinutes: interval,
    );
  }

  String _resolveSyncTargetKey() {
    final selectedKey = selectedSyncKey.value.trim();
    if (selectedKey.isNotEmpty) {
      return selectedKey;
    }
    return defaultSyncInboxKey.value.trim();
  }

  Future<void> syncSms({String trigger = 'manual'}) async {
    if (isSyncing.value) {
      return;
    }

    final key = _resolveSyncTargetKey();
    if (key.isEmpty) {
      status.value = 'Set a default sync inbox in Settings first.';
      return;
    }

    if (kIsWeb || defaultTargetPlatform == TargetPlatform.iOS) {
      status.value =
          'SMS inbox reading is only available on Android. iOS does not allow this.';
      return;
    }

    isSyncing.value = true;

    try {
      if (trigger == 'manual') {
        status.value = 'Requesting SMS permission...';
      } else {
        status.value = 'Auto-syncing SMS ($trigger)...';
      }

      final syncedCount = await _syncService.syncInboxByKey(
        key,
        requestPermission: true,
      );

      if (syncedCount < 0) {
        status.value = 'SMS permission denied.';
        return;
      }

      if (trigger == 'manual') {
        status.value = 'Synced $syncedCount messages to Firebase.';
      } else {
        status.value = 'Auto-sync ($trigger) complete: $syncedCount messages.';
      }
    } catch (error) {
      status.value = 'Sync failed: $error';
    } finally {
      isSyncing.value = false;
    }
  }

  Future<void> syncCalls({String trigger = 'manual'}) async {
    if (isSyncing.value) {
      return;
    }

    final key = _resolveSyncTargetKey();
    if (key.isEmpty) {
      status.value = 'Set a default sync inbox in Settings first.';
      return;
    }

    if (kIsWeb || defaultTargetPlatform == TargetPlatform.iOS) {
      status.value =
          'Call log reading is only available on Android. iOS does not allow this.';
      return;
    }

    isSyncing.value = true;

    try {
      if (trigger == 'manual') {
        status.value = 'Requesting call log permission...';
      } else {
        status.value = 'Auto-syncing calls ($trigger)...';
      }

      final syncedCount = await _syncService.syncCallsByKey(
        key,
        requestPermission: true,
      );

      if (syncedCount < 0) {
        status.value = 'Call log permission denied.';
        return;
      }

      if (trigger == 'manual') {
        status.value = 'Synced $syncedCount call logs to Firebase.';
      } else {
        status.value = 'Auto-sync calls ($trigger) complete: $syncedCount.';
      }
    } catch (error) {
      status.value = 'Call sync failed: $error';
    } finally {
      isSyncing.value = false;
    }
  }

  Future<void> syncAll({String trigger = 'manual'}) async {
    if (trigger == 'manual') {
      await syncSms(trigger: trigger);
    } else {
      await SmsSyncDebugLog.append(
        'Skipping SMS scan for $trigger; incoming SMS is handled by native receiver.',
      );
    }
    await syncCalls(trigger: trigger);
  }

  Future<void> pullFromFirebase({bool silent = false}) async {
    if (isPulling.value) {
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (!silent) {
        status.value = 'Not signed in. Please sign in again.';
      }
      return;
    }

    isPulling.value = true;
    try {
      final inboxes =
          await _userInboxesRef(uid).get(const GetOptions(source: Source.server));
      final activeKeys =
          inboxes.docs
              .where((doc) => doc.data()['isDeleted'] != true)
              .map((doc) => ((doc.data()['syncKey'] as String?) ?? doc.id).trim())
              .where((key) => key.isNotEmpty)
              .toSet();

      final selectedKey = selectedSyncKey.value.trim();
      if (selectedKey.isNotEmpty && !activeKeys.contains(selectedKey)) {
        clearSelectedInbox();
      }

      if (selectedKey.isNotEmpty) {
        await Future.wait([
          _firestore
              .collection('sync_keys')
              .doc(selectedKey)
              .collection('sms')
              .orderBy('smsDate', descending: true)
              .limit(100)
              .get(const GetOptions(source: Source.server)),
          _firestore
              .collection('sync_keys')
              .doc(selectedKey)
              .collection('calls')
              .orderBy('callDate', descending: true)
              .limit(100)
              .get(const GetOptions(source: Source.server)),
        ]);
      }

      if (!silent) {
        status.value =
            selectedKey.isEmpty
                ? 'Refreshed inbox list from Firebase.'
                : 'Refreshed inbox + chats from Firebase.';
      }
    } catch (e) {
      if (!silent) {
        status.value = 'Refresh failed: $e';
      }
    } finally {
      isPulling.value = false;
    }
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> syncedMessagesStream() {
    final key = selectedSyncKey.value;
    if (key.isEmpty) {
      return const Stream.empty();
    }

    return _firestore
        .collection('sync_keys')
        .doc(key)
        .collection('sms')
        .orderBy('smsDate', descending: true)
        .limit(100)
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> syncedCallsStream() {
    final key = selectedSyncKey.value;
    if (key.isEmpty) {
      return const Stream.empty();
    }

    return _firestore
        .collection('sync_keys')
        .doc(key)
        .collection('calls')
        .orderBy('callDate', descending: true)
        .limit(100)
        .snapshots();
  }

  String decryptForDisplay(String? value) {
    if ((value ?? '').isEmpty) {
      return '';
    }
    return _syncService.decryptTextForDisplay(value!);
  }

  String _hashPassword(String input) {
    return sha256.convert(utf8.encode(input)).toString();
  }

  Future<bool> _authenticateWithBiometric({required String reason}) async {
    if (kIsWeb) {
      return false;
    }
    try {
      return await _localAuth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }
}
