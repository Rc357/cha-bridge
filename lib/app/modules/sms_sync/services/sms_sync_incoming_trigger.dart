import 'sms_sync_debug_log.dart';

bool _incomingTriggerInitialized = false;

Future<void> initializeIncomingSmsTrigger() async {
  if (_incomingTriggerInitialized) {
    return;
  }

  _incomingTriggerInitialized = true;
  await SmsSyncDebugLog.append(
    'Incoming SMS handled by native Android receiver.',
  );
}
