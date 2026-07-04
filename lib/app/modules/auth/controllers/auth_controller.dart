import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:local_auth/local_auth.dart';

class AuthController extends GetxController {
  static const _savedEmailKey = 'saved_login_email';
  static const _savedPasswordKey = 'saved_login_password';

  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final isLogin = true.obs;
  final isSubmitting = false.obs;
  final status = ''.obs;
  final canUseBiometricLogin = false.obs;

  final LocalAuthentication _localAuth = LocalAuthentication();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  void onInit() {
    super.onInit();
    _refreshBiometricCapability();
  }

  @override
  void onClose() {
    emailController.dispose();
    passwordController.dispose();
    super.onClose();
  }

  Future<void> submitEmailPassword() async {
    final email = emailController.text.trim();
    final password = passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      status.value = 'Email and password are required.';
      return;
    }

    isSubmitting.value = true;
    status.value = isLogin.value ? 'Signing in...' : 'Creating account...';

    try {
      if (isLogin.value) {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
      } else {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
      }
      await _saveLoginCredentials(email: email, password: password);
      await _refreshBiometricCapability();
    } on FirebaseAuthException catch (e) {
      status.value = e.message ?? 'Authentication failed.';
    } catch (e) {
      status.value = 'Authentication failed: $e';
    } finally {
      isSubmitting.value = false;
    }
  }

  Future<void> signInWithBiometrics() async {
    isSubmitting.value = true;
    status.value = 'Checking biometric login...';

    try {
      final email = await _storage.read(key: _savedEmailKey);
      final password = await _storage.read(key: _savedPasswordKey);
      if ((email ?? '').isEmpty || (password ?? '').isEmpty) {
        status.value = 'No saved login found. Sign in with email once first.';
        return;
      }

      final isSupported = await _localAuth.isDeviceSupported();
      final canCheckBiometrics = await _localAuth.canCheckBiometrics;
      if (!isSupported || !canCheckBiometrics) {
        status.value = 'Biometric login is not available on this device.';
        return;
      }

      final didAuthenticate = await _localAuth.authenticate(
        localizedReason: 'Use fingerprint to login to Cha Bridge',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
      if (!didAuthenticate) {
        status.value = 'Biometric login cancelled.';
        return;
      }

      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email!,
        password: password!,
      );
      status.value = 'Biometric login successful.';
    } catch (e) {
      status.value = 'Biometric login failed: $e';
    } finally {
      isSubmitting.value = false;
      await _refreshBiometricCapability();
    }
  }

  Future<void> _saveLoginCredentials({
    required String email,
    required String password,
  }) async {
    await _storage.write(key: _savedEmailKey, value: email);
    await _storage.write(key: _savedPasswordKey, value: password);
  }

  Future<void> _refreshBiometricCapability() async {
    try {
      final isSupported = await _localAuth.isDeviceSupported();
      final canCheckBiometrics = await _localAuth.canCheckBiometrics;
      final email = await _storage.read(key: _savedEmailKey);
      final password = await _storage.read(key: _savedPasswordKey);
      canUseBiometricLogin.value =
          isSupported &&
          canCheckBiometrics &&
          (email ?? '').isNotEmpty &&
          (password ?? '').isNotEmpty;
    } catch (_) {
      canUseBiometricLogin.value = false;
    }
  }

  Future<void> signInWithGoogle() async {
    if (kIsWeb) {
      status.value = 'Google sign-in not configured for web in this app.';
      return;
    }

    isSubmitting.value = true;
    status.value = 'Signing in with Google...';

    try {
      await GoogleSignIn.instance.initialize();
      final googleUser = await GoogleSignIn.instance.authenticate();
      final googleAuth = googleUser.authentication;
      if ((googleAuth.idToken ?? '').isEmpty) {
        status.value =
            'Google sign-in is not configured in Firebase (missing OAuth/SHA setup).';
        return;
      }

      final credential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
    } on FirebaseAuthException catch (e) {
      status.value = 'Google sign-in failed [${e.code}]: ${e.message ?? ''}';
    } catch (e) {
      status.value = 'Google sign-in failed: $e';
    } finally {
      isSubmitting.value = false;
    }
  }

  void toggleMode() {
    isLogin.value = !isLogin.value;
    status.value = '';
  }
}
