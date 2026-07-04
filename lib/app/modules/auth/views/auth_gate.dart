import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../sms_sync/bindings/sms_sync_binding.dart';
import '../../sms_sync/views/sms_sync_screen.dart';
import '../bindings/auth_binding.dart';
import 'auth_screen.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.data == null) {
          AuthBinding().dependencies();
          return const AuthScreen();
        }

        SmsSyncBinding().dependencies();
        return const SmsSyncScreen();
      },
    );
  }
}
