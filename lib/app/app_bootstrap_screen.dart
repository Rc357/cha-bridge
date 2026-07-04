import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'modules/auth/views/auth_gate.dart';

class AppBootstrapScreen extends StatelessWidget {
  const AppBootstrapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: Firebase.initializeApp(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError) {
          return Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Firebase init failed. Add google-services.json (Android) and '
                'GoogleService-Info.plist (iOS) first.\n\nError: ${snapshot.error}',
              ),
            ),
          );
        }

        return const AuthGate();
      },
    );
  }
}
