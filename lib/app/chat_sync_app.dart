import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'app_bootstrap_screen.dart';
import 'app_flavor.dart';
import 'theme_controller.dart';

class ChatSyncApp extends StatelessWidget {
  const ChatSyncApp({
    super.key,
    this.flavor = AppFlavor.production,
  });

  final AppFlavor flavor;

  @override
  Widget build(BuildContext context) {
    const brandMint = Color(0xFF0E9F8A);
    const brandMintDark = Color(0xFF0A6A5C);
    const lightSurface = Color(0xFFF4FAF8);
    const lightBorder = Color(0xFFD0E7E1);

    final themeController =
        Get.isRegistered<AppThemeController>()
            ? Get.find<AppThemeController>()
            : Get.put(AppThemeController(), permanent: true);

    final lightBase = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: brandMint,
        brightness: Brightness.light,
      ),
      useMaterial3: true,
    );

    final darkBase = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: brandMint,
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    );

    return Obx(
      () => GetMaterialApp(
        title: '${flavor.titlePrefix}Cha Bridge',
        debugShowCheckedModeBanner: false,
        themeMode: themeController.themeMode.value,
        theme: lightBase.copyWith(
          scaffoldBackgroundColor: lightSurface,
          appBarTheme: const AppBarTheme(
            backgroundColor: lightSurface,
            foregroundColor: Colors.black87,
            elevation: 0,
          ),
          cardTheme: CardThemeData(
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: const BorderSide(color: lightBorder),
            ),
          ),
          bottomNavigationBarTheme: const BottomNavigationBarThemeData(
            backgroundColor: Colors.white,
            selectedItemColor: brandMint,
            unselectedItemColor: Color(0xFF7D908C),
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: brandMint,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: lightBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: lightBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: brandMintDark, width: 1.4),
            ),
          ),
        ),
        darkTheme: darkBase.copyWith(
          scaffoldBackgroundColor: const Color(0xFF111716),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF111716),
            foregroundColor: Colors.white,
            elevation: 0,
          ),
          bottomNavigationBarTheme: BottomNavigationBarThemeData(
            backgroundColor: const Color(0xFF1A2220),
            selectedItemColor: darkBase.colorScheme.primary,
            unselectedItemColor: Colors.white54,
          ),
          cardTheme: CardThemeData(
            color: const Color(0xFF1A2220),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        ),
        home: const AppBootstrapScreen(),
      ),
    );
  }
}
