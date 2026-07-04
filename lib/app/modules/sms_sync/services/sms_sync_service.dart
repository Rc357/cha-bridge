import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:call_log/call_log.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telephony/telephony.dart';

import '../../../services/security/data_cipher.dart';
import 'sms_sync_debug_log.dart';

class SmsSyncService {
  SmsSyncService({
    FirebaseFirestore? firestore,
    Telephony? telephony,
    DataCipher? dataCipher,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _telephony = telephony ?? Telephony.instance,
       _dataCipher = dataCipher ?? DataCipher();

  final FirebaseFirestore _firestore;
  final Telephony _telephony;
  final DataCipher _dataCipher;
  static const _prefLastSmsSyncMsPrefix = 'last_sms_sync_ms_';
  static const _prefLastCallSyncMsPrefix = 'last_call_sync_ms_';
  static const _clockSkewToleranceMs = 5 * 60 * 1000;

  Future<void> initializeCrypto() async {
    await _dataCipher.init();
  }

  String decryptTextForDisplay(String value) {
    return _dataCipher.decryptTextSync(value);
  }

  Future<bool> ensureSmsPermission({required bool requestIfNeeded}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }

    if (!requestIfNeeded) {
      // In background isolates, permission status checks can be unreliable.
      // Let the actual SMS read call determine access.
      return true;
    }

    final result = await Permission.sms.request();
    return result.isGranted;
  }

  Future<bool> ensureCallPermission({required bool requestIfNeeded}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }

    if (!requestIfNeeded) {
      // In background isolates, permission status checks can be unreliable.
      // Let call-log read determine access.
      return true;
    }

    final result = await Permission.phone.request();
    return result.isGranted;
  }

  Future<bool> ensureSyncPermissions({required bool requestIfNeeded}) async {
    final smsOk = await ensureSmsPermission(requestIfNeeded: requestIfNeeded);
    final callOk = await ensureCallPermission(requestIfNeeded: requestIfNeeded);
    return smsOk && callOk;
  }

  Future<int> syncInboxByKey(
    String syncKey, {
    int limit = 200,
    bool requestPermission = true,
  }) async {
    await SmsSyncDebugLog.append(
      'syncInboxByKey start: key=$syncKey limit=$limit requestPermission=$requestPermission',
    );
    await initializeCrypto();
    final permissionOk = await ensureSmsPermission(
      requestIfNeeded: requestPermission,
    );
    if (!permissionOk) {
      await SmsSyncDebugLog.append('syncInboxByKey denied: SMS permission');
      return -1;
    }

    late final List<SmsMessage> messages;
    try {
      messages = await _telephony.getInboxSms(
        columns: <SmsColumn>[
          SmsColumn.ADDRESS,
          SmsColumn.BODY,
          SmsColumn.DATE,
          SmsColumn.DATE_SENT,
          SmsColumn.THREAD_ID,
        ],
        sortOrder: <OrderBy>[OrderBy(SmsColumn.DATE, sort: Sort.DESC)],
      );
    } catch (e) {
      await SmsSyncDebugLog.append('syncInboxByKey getInboxSms failed: $e');
      return -1;
    }

    final latestMessages = messages.take(limit).toList();
    final prefs = await SharedPreferences.getInstance();
    final lastSyncMs = prefs.getInt('$_prefLastSmsSyncMsPrefix$syncKey') ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final effectiveLastSyncMs =
        lastSyncMs > nowMs + _clockSkewToleranceMs
            ? nowMs
            : lastSyncMs;
    final messagesToSync =
        latestMessages.where((sms) {
          final smsMs = sms.date ?? sms.dateSent ?? 0;
          return smsMs > effectiveLastSyncMs;
        }).toList();
    if (messagesToSync.isEmpty &&
        latestMessages.isNotEmpty &&
        effectiveLastSyncMs == 0) {
      // Fallback: push a tiny recent window so new items are not blocked by
      // provider timestamp anomalies during first-time sync. Do not do this
      // after an incoming-SMS native upload, or a background scanner can create
      // a duplicate document with a different timestamp-derived id.
      messagesToSync.addAll(latestMessages.take(3));
    }
    if (messagesToSync.isEmpty) {
      await SmsSyncDebugLog.append('syncInboxByKey no new messages: key=$syncKey');
      return 0;
    }
    final batch = _firestore.batch();
    var maxSyncedMs = effectiveLastSyncMs;

    for (final sms in messagesToSync) {
      final docId = _messageId(sms);
      final docRef = _firestore
          .collection('sync_keys')
          .doc(syncKey)
          .collection('sms')
          .doc(docId);

      batch.set(docRef, {
        'address': _dataCipher.encryptTextSync(sms.address ?? 'Unknown'),
        'body': _dataCipher.encryptTextSync(sms.body ?? ''),
        'threadId': sms.threadId,
        'smsDate': Timestamp.fromMillisecondsSinceEpoch(
          sms.date ?? sms.dateSent ?? 0,
        ),
        'uploadedAt': FieldValue.serverTimestamp(),
        'source': 'android',
      }, SetOptions(merge: true));
      final smsMs = sms.date ?? sms.dateSent ?? 0;
      if (smsMs > maxSyncedMs) {
        maxSyncedMs = smsMs;
      }
    }

    try {
      await batch.commit();
      await prefs.setInt('$_prefLastSmsSyncMsPrefix$syncKey', maxSyncedMs);
      await SmsSyncDebugLog.append(
        'syncInboxByKey commit ok: key=$syncKey count=${messagesToSync.length} lastMs=$maxSyncedMs',
      );
      return messagesToSync.length;
    } on FirebaseException catch (e) {
      await SmsSyncDebugLog.append(
        'syncInboxByKey commit failed: key=$syncKey code=${e.code} message=${e.message}',
      );
      return -1;
    } catch (e) {
      await SmsSyncDebugLog.append('syncInboxByKey commit failed: key=$syncKey error=$e');
      return -1;
    }
  }

  Future<int> syncAllInboxesForCurrentUser({
    int limit = 200,
    bool requestPermission = false,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return 0;
    }

    final inboxesSnapshot =
        await _firestore
            .collection('users')
            .doc(uid)
            .collection('inboxes')
            .get();

    if (inboxesSnapshot.docs.isEmpty) {
      return 0;
    }

    var totalSynced = 0;
    for (final inboxDoc in inboxesSnapshot.docs) {
      final data = inboxDoc.data();
      final isDeleted = data['isDeleted'] == true;
      if (isDeleted) {
        continue;
      }
      final syncKey = (data['syncKey'] as String?)?.trim() ?? inboxDoc.id;
      if (syncKey.isEmpty) {
        continue;
      }

      final syncedCount = await syncInboxByKey(
        syncKey,
        limit: limit,
        requestPermission: requestPermission,
      );
      if (syncedCount < 0) {
        return -1;
      }
      totalSynced += syncedCount;
    }
    return totalSynced;
  }

  Future<int> syncCallsByKey(
    String syncKey, {
    int limit = 200,
    bool requestPermission = true,
  }) async {
    await initializeCrypto();
    final permissionOk = await ensureCallPermission(
      requestIfNeeded: requestPermission,
    );
    if (!permissionOk) {
      return -1;
    }
    Iterable<CallLogEntry> rawCalls;
    try {
      rawCalls = await CallLog.get();
    } catch (_) {
      return -1;
    }
    final sortedCalls =
        rawCalls.toList()..sort(
          (a, b) => (b.timestamp ?? 0).compareTo(a.timestamp ?? 0),
        );
    final latestCalls = sortedCalls.take(limit).toList();
    final prefs = await SharedPreferences.getInstance();
    final lastSyncMs = prefs.getInt('$_prefLastCallSyncMsPrefix$syncKey') ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final effectiveLastSyncMs =
        lastSyncMs > nowMs + _clockSkewToleranceMs ? 0 : lastSyncMs;
    final callsToSync =
        latestCalls
            .where((call) => (call.timestamp ?? 0) > effectiveLastSyncMs)
            .toList();
    if (callsToSync.isEmpty && latestCalls.isNotEmpty) {
      callsToSync.addAll(latestCalls.take(3));
    }
    if (callsToSync.isEmpty) {
      return 0;
    }
    final batch = _firestore.batch();
    var maxSyncedMs = effectiveLastSyncMs;

    for (final call in callsToSync) {
      final callDateMs = call.timestamp ?? 0;
      final docId = _callId(call);
      final docRef = _firestore
          .collection('sync_keys')
          .doc(syncKey)
          .collection('calls')
          .doc(docId);

      batch.set(docRef, {
        'number': _dataCipher.encryptTextSync(call.number ?? 'Unknown'),
        'name':
            call.name == null
                ? null
                : _dataCipher.encryptTextSync(call.name!),
        'callType': _dataCipher.encryptTextSync(
          (call.callType ?? CallType.unknown).name,
        ),
        'durationSec': call.duration ?? 0,
        'callDate': Timestamp.fromMillisecondsSinceEpoch(callDateMs),
        'uploadedAt': FieldValue.serverTimestamp(),
        'source': 'android',
      }, SetOptions(merge: true));
      if (callDateMs > maxSyncedMs) {
        maxSyncedMs = callDateMs;
      }
    }

    await batch.commit();
    await prefs.setInt('$_prefLastCallSyncMsPrefix$syncKey', maxSyncedMs);
    return callsToSync.length;
  }

  Future<int> syncAllCallsForCurrentUser({
    int limit = 200,
    bool requestPermission = false,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return 0;
    }

    final inboxesSnapshot =
        await _firestore
            .collection('users')
            .doc(uid)
            .collection('inboxes')
            .get();

    if (inboxesSnapshot.docs.isEmpty) {
      return 0;
    }

    var totalSynced = 0;
    for (final inboxDoc in inboxesSnapshot.docs) {
      final data = inboxDoc.data();
      final isDeleted = data['isDeleted'] == true;
      if (isDeleted) {
        continue;
      }
      final syncKey = (data['syncKey'] as String?)?.trim() ?? inboxDoc.id;
      if (syncKey.isEmpty) {
        continue;
      }

      final syncedCount = await syncCallsByKey(
        syncKey,
        limit: limit,
        requestPermission: requestPermission,
      );
      if (syncedCount < 0) {
        return -1;
      }
      totalSynced += syncedCount;
    }
    return totalSynced;
  }

  String _messageId(SmsMessage sms) {
    final raw = '${sms.address}|${sms.date}|${sms.body}';
    return sha1.convert(utf8.encode(raw)).toString();
  }

  String _callId(CallLogEntry call) {
    final raw =
        '${call.number}|${call.timestamp}|${call.duration}|${call.callType?.name}';
    return sha1.convert(utf8.encode(raw)).toString();
  }
}
