import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:workmanager/workmanager.dart';

import 'app_flavor.dart';
import 'chat_sync_app.dart';
import 'modules/sms_sync/services/sms_sync_background.dart';

Future<void> runChaBridgeApp(AppFlavor flavor) async {
  WidgetsFlutterBinding.ensureInitialized();

  await runZonedGuarded<Future<void>>(
    () async {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);

      FlutterForegroundTask.initCommunicationPort();
      await Workmanager().initialize(smsSyncBackgroundDispatcher);

      if (kDebugMode) {
        debugPrint('CURRENT FLAVOR: ${flavor.description}');
      }

      runApp(ChatSyncApp(flavor: flavor));
    },
    (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Cha Bridge bootstrap',
        ),
      );
    },
  );
}
