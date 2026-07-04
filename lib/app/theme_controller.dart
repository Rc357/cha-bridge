import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppThemeController extends GetxController {
  static const _prefDarkMode = 'dark_mode_enabled';

  final themeMode = ThemeMode.light.obs;

  bool get isDarkMode => themeMode.value == ThemeMode.dark;

  @override
  void onInit() {
    super.onInit();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool(_prefDarkMode) ?? false;
    themeMode.value = isDark ? ThemeMode.dark : ThemeMode.light;
  }

  Future<void> setDarkMode(bool enabled) async {
    themeMode.value = enabled ? ThemeMode.dark : ThemeMode.light;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefDarkMode, enabled);
  }
}
