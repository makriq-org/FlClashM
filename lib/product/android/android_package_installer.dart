import 'package:flutter/services.dart';

abstract interface class AndroidPackageInstaller {
  Future<bool> install(String path);
}

class MethodChannelAndroidPackageInstaller implements AndroidPackageInstaller {
  const MethodChannelAndroidPackageInstaller();

  static const _channel = MethodChannel('app');

  @override
  Future<bool> install(String path) async =>
      await _channel.invokeMethod<bool>(
        'installPackage',
        {'path': path},
      ) ??
      false;
}
