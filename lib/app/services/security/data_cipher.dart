import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class DataCipher {
  static const _storageKey = 'chabridge_data_cipher_key_v1';
  static const _remoteDocId = 'dataCipher';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  enc.Encrypter? _encrypter;

  Future<void> init() async {
    if (_encrypter != null) {
      return;
    }

    var keyBase64 = await _storage.read(key: _storageKey);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if ((uid ?? '').isNotEmpty) {
      final secretRef = _firestore
          .collection('users')
          .doc(uid)
          .collection('secrets')
          .doc(_remoteDocId);
      try {
        final secretDoc = await secretRef.get();
        final remoteKey = (secretDoc.data()?['keyBase64'] as String?)?.trim();

        if ((remoteKey ?? '').isNotEmpty) {
          if (keyBase64 != remoteKey) {
            keyBase64 = remoteKey;
            await _storage.write(key: _storageKey, value: keyBase64);
          }
        } else if ((keyBase64 ?? '').isNotEmpty) {
          await secretRef.set({
            'keyBase64': keyBase64,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        } else {
          keyBase64 = enc.Key.fromSecureRandom(32).base64;
          await _storage.write(key: _storageKey, value: keyBase64);
          await secretRef.set({
            'keyBase64': keyBase64,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      } catch (_) {
        // Fall back to local-only key if remote sync is not reachable.
      }
    }

    if ((keyBase64 ?? '').isEmpty) {
      keyBase64 = enc.Key.fromSecureRandom(32).base64;
      await _storage.write(key: _storageKey, value: keyBase64);
    }

    final key = enc.Key.fromBase64(keyBase64!);
    _encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
  }

  String encryptTextSync(String plainText) {
    if (_encrypter == null) {
      throw StateError('DataCipher is not initialized.');
    }
    final iv = enc.IV.fromSecureRandom(16);
    final encrypted = _encrypter!.encrypt(plainText, iv: iv);
    return '${iv.base64}:${encrypted.base64}';
  }

  String decryptTextSync(String value) {
    if (_encrypter == null || !value.contains(':')) {
      return value;
    }
    try {
      final parts = value.split(':');
      if (parts.length != 2) {
        return value;
      }
      final iv = enc.IV.fromBase64(parts[0]);
      return _encrypter!.decrypt64(parts[1], iv: iv);
    } catch (_) {
      return value;
    }
  }
}
