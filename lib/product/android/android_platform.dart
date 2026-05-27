import 'android_foreground_notification_policy.dart';
import 'android_runtime_access_policy.dart';
import 'android_update_bridge.dart';

class AndroidPlatformServices {
  const AndroidPlatformServices({
    this.foregroundNotification = const AndroidForegroundNotificationPolicy(),
    this.runtimeAccess = const AndroidRuntimeAccessPolicy(),
    this.updateBridge = const AndroidUpdateBridge(),
  });

  final AndroidForegroundNotificationPolicy foregroundNotification;
  final AndroidRuntimeAccessPolicy runtimeAccess;
  final AndroidUpdateBridge updateBridge;
}

const androidPlatform = AndroidPlatformServices();
