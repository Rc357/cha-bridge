import 'app/app_flavor.dart';
import 'app/app_runner.dart';

Future<void> main() async {
  await runChaBridgeApp(AppFlavor.staging);
}

/*
# Run in staging
flutter run -t lib/main_staging.dart --flavor=staging

# Build APK (staging)
flutter build apk -t lib/main_staging.dart --flavor=staging

# Build App Bundle (staging)
flutter build appbundle -t lib/main_staging.dart --flavor=staging
*/
