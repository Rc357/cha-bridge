import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:developer' as dev;

class SmsSyncDebugLog {
  static const _prefKey = 'sms_sync_debug_logs_v1';
  static const _nativePrefKey = 'sms_sync_native_debug_logs_v1';
  static const _maxEntries = 120;

  static Future<void> append(String message) async {
    final prefs = await SharedPreferences.getInstance();
    final logs = prefs.getStringList(_prefKey) ?? <String>[];
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts] $message';
    logs.add(line);
    // Terminal/logcat visible logs for debugging.
    dev.log(line, name: 'ChaBridgeSync');
    // ignore: avoid_print
    print('ChaBridgeSync: $line');
    if (logs.length > _maxEntries) {
      logs.removeRange(0, logs.length - _maxEntries);
    }
    await prefs.setStringList(_prefKey, logs);
  }

  static Future<List<String>> read() async {
    final prefs = await SharedPreferences.getInstance();
    final logs = prefs.getStringList(_prefKey) ?? <String>[];
    final nativeLogs = _readNativeLogs(prefs);
    return <String>[...logs, ...nativeLogs].reversed.toList();
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
    await prefs.remove(_nativePrefKey);
  }

  static List<String> _readNativeLogs(SharedPreferences prefs) {
    final rawLogs = prefs.getString(_nativePrefKey);
    if (rawLogs == null || rawLogs.isEmpty) {
      return <String>[];
    }
    try {
      final decoded = jsonDecode(rawLogs);
      if (decoded is List) {
        return decoded.whereType<String>().toList();
      }
    } catch (_) {}
    return <String>[];
  }
}
