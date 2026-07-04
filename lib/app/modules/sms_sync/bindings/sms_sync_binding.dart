import 'package:get/get.dart';

import '../controllers/sms_sync_controller.dart';

class SmsSyncBinding extends Bindings {
  @override
  void dependencies() {
    if (!Get.isRegistered<SmsSyncController>()) {
      Get.put(SmsSyncController());
    }
  }
}
