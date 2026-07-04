import 'app/app_flavor.dart';
import 'app/app_runner.dart';

Future<void> main() async {
  await runChaBridgeApp(AppFlavor.production);
}

/*
# Run in production
flutter run -t lib/main_production.dart --flavor=production

# Build APK (production)
flutter build apk -t lib/main_production.dart --flavor=production

# Build App Bundle (production)
flutter build appbundle -t lib/main_production.dart --flavor=production
*/
