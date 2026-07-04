import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../widgets/chabridge_logo.dart';
import '../controllers/auth_controller.dart';

class AuthScreen extends StatelessWidget {
  const AuthScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<AuthController>();
    final theme = Theme.of(context);

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0A6A5C), Color(0xFF0E9F8A), Color(0xFFF4FAF8)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 420),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.96),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x22000000),
                      blurRadius: 20,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: theme.colorScheme.primary.withValues(
                                  alpha: 0.25,
                                ),
                                blurRadius: 14,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: const ChaBridgeLogo(size: 44),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Cha Bridge',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              'Viber-style SMS sync',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: const Color(0xFF6E6E86),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: controller.emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.mail_outline),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller.passwordController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Password',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: Obx(
                        () => ElevatedButton(
                          onPressed:
                              controller.isSubmitting.value
                                  ? null
                                  : controller.submitEmailPassword,
                          child: Text(
                            controller.isSubmitting.value
                                ? 'Please wait...'
                                : controller.isLogin.value
                                ? 'Login'
                                : 'Create Account',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: Obx(
                        () => OutlinedButton.icon(
                          onPressed:
                              controller.isSubmitting.value
                                  ? null
                                  : controller.signInWithGoogle,
                          icon: const Icon(Icons.g_mobiledata),
                          label: const Text('Sign in with Google'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Obx(
                      () =>
                          controller.canUseBiometricLogin.value
                              ? SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed:
                                      controller.isSubmitting.value
                                          ? null
                                          : controller.signInWithBiometrics,
                                  icon: const Icon(Icons.fingerprint),
                                  label: const Text('Sign in with Fingerprint'),
                                ),
                              )
                              : const SizedBox.shrink(),
                    ),
                    const SizedBox(height: 8),
                    Obx(
                      () => TextButton(
                        onPressed:
                            controller.isSubmitting.value
                                ? null
                                : controller.toggleMode,
                        child: Text(
                          controller.isLogin.value
                              ? 'No account? Create one'
                              : 'Already have an account? Login',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Obx(
                        () => Text(
                          controller.status.value,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: const Color(0xFF54546A),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
