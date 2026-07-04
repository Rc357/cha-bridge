import 'app/app_flavor.dart';
import 'app/app_runner.dart';

Future<void> main() async {
  await runChaBridgeApp(AppFlavor.development);
}

/*
# Run in development
flutter run -t lib/main_development.dart --flavor=development

# Build APK (development)
flutter build apk -t lib/main_development.dart --flavor=development

# Build App Bundle (development)
flutter build appbundle -t lib/main_development.dart --flavor=development
*/
