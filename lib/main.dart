import 'app/app_flavor.dart';
import 'app/app_runner.dart';

Future<void> main() async {
  await runChaBridgeApp(AppFlavor.production);
}
