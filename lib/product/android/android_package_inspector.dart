import 'package:flutter/services.dart';

import '../services/app_update_identity.dart';

/// Android сообщает личность установленного приложения и скачанного APK.
/// Отдельный канал от установки: проверка не должна запускать установщик.
abstract interface class AndroidPackageInspector {
  Future<AppUpdatePackageIdentity?> inspectInstalled();

  Future<AppUpdatePackageIdentity?> inspectApk(String path);
}

class MethodChannelAndroidPackageInspector implements AndroidPackageInspector {
  const MethodChannelAndroidPackageInspector();

  static const _channel = MethodChannel('app');

  @override
  Future<AppUpdatePackageIdentity?> inspectInstalled() async {
    final result = await _channel.invokeMethod<Object?>(
      'installedPackageIdentity',
    );
    return AppUpdatePackageIdentity.tryFromMap(result);
  }

  @override
  Future<AppUpdatePackageIdentity?> inspectApk(String path) async {
    final result = await _channel.invokeMethod<Object?>(
      'inspectPackageIdentity',
      {'path': path},
    );
    return AppUpdatePackageIdentity.tryFromMap(result);
  }
}
