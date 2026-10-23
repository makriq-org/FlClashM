import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../clash/clash.dart';
import '../../enum/enum.dart';
import '../../models/models.dart';
import '../../plugins/app.dart';

@immutable
class ProfileAccessSnapshot {
  const ProfileAccessSnapshot.available(this.accessControl) : available = true;

  const ProfileAccessSnapshot.unavailable()
    : available = false,
      accessControl = null;

  final bool available;
  final AccessControl? accessControl;
}

abstract interface class RuntimeAccessPlatformBridge {
  bool get isAndroid;

  Future<List<Package>> readPackages();

  Future<ImageProvider?> readPackageIcon(String packageName);

  /// Reads the immutable options snapshot used to establish the live Android
  /// VPN. An available snapshot with null access control means that the VPN
  /// explicitly has no profile package rule; unavailable means the remote
  /// service could not provide a trustworthy snapshot.
  Future<ProfileAccessSnapshot> readAppliedProfileAccess();
}

class AndroidRuntimeAccessPolicy implements RuntimeAccessPlatformBridge {
  const AndroidRuntimeAccessPolicy({this.appliedOptionsReader});

  final Future<String> Function()? appliedOptionsReader;

  @override
  bool get isAndroid => Platform.isAndroid;

  @override
  Future<List<Package>> readPackages() async => await app?.getPackages() ?? [];

  @override
  Future<ImageProvider?> readPackageIcon(String packageName) =>
      app?.getPackageIcon(packageName) ?? Future.value(null);

  @override
  Future<ProfileAccessSnapshot> readAppliedProfileAccess() async {
    final optionsJson =
        await (appliedOptionsReader?.call() ??
            clashLib?.getAppliedAndroidVpnOptions() ??
            Future.value(''));
    if (optionsJson.isEmpty) {
      return const ProfileAccessSnapshot.unavailable();
    }
    try {
      final options = json.decode(optionsJson) as Map<String, dynamic>;
      final include = _readNullableStringList(options, 'includePackage');
      final exclude = _readNullableStringList(options, 'excludePackage');
      if (include != null && exclude != null) {
        return const ProfileAccessSnapshot.unavailable();
      }
      if (include != null) {
        return ProfileAccessSnapshot.available(
          AccessControl(
            enable: true,
            mode: AccessControlMode.acceptSelected,
            acceptList: include,
          ),
        );
      }
      if (exclude != null) {
        return ProfileAccessSnapshot.available(
          AccessControl(
            enable: true,
            mode: AccessControlMode.rejectSelected,
            rejectList: exclude,
          ),
        );
      }
      return const ProfileAccessSnapshot.available(null);
    } catch (_) {
      return const ProfileAccessSnapshot.unavailable();
    }
  }

  List<String>? _readNullableStringList(
    Map<String, dynamic> options,
    String key,
  ) {
    final value = options[key];
    if (value == null) {
      return null;
    }
    if (value is! List || value.any((item) => item is! String)) {
      throw FormatException('Invalid `$key` in applied VPN options.');
    }
    return List<String>.unmodifiable(value.cast<String>());
  }
}
