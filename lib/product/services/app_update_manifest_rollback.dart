import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_update_manifest.dart';

abstract interface class AppUpdateManifestRollbackGuard {
  Future<void> validateAndRecord(AppUpdateManifest manifest);
}

class SharedPreferencesAppUpdateManifestRollbackGuard
    implements AppUpdateManifestRollbackGuard {
  const SharedPreferencesAppUpdateManifestRollbackGuard();

  static const _keyPrefix = 'flclashm.appUpdate.highestManifest';

  @override
  Future<void> validateAndRecord(AppUpdateManifest manifest) async {
    final preferences = await SharedPreferences.getInstance();
    final channelKey = '$_keyPrefix.${manifest.channel.wireName}';
    final highest = _readHighestManifestState(
      preferences.getString(channelKey),
    );
    final publishedAt = manifest.publishedAt.millisecondsSinceEpoch;

    if (manifest.versionCode < highest.versionCode ||
        (manifest.versionCode == highest.versionCode &&
            publishedAt < highest.publishedAtMillis)) {
      throw const FormatException('App update manifest rollback rejected.');
    }
    if (manifest.versionCode > highest.versionCode ||
        publishedAt > highest.publishedAtMillis) {
      final stored = await preferences.setString(
        channelKey,
        jsonEncode({
          'versionCode': manifest.versionCode,
          'publishedAtMillis': publishedAt,
        }),
      );
      if (!stored) {
        throw StateError('Unable to persist app update rollback state.');
      }
    }
  }
}

({int versionCode, int publishedAtMillis}) _readHighestManifestState(
  String? raw,
) {
  if (raw == null) {
    return (versionCode: 0, publishedAtMillis: 0);
  }
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Invalid app update rollback state.');
  }
  final versionCode = decoded['versionCode'];
  final publishedAtMillis = decoded['publishedAtMillis'];
  if (versionCode is! int ||
      versionCode < 0 ||
      publishedAtMillis is! int ||
      publishedAtMillis < 0) {
    throw const FormatException('Invalid app update rollback state.');
  }
  return (
    versionCode: versionCode,
    publishedAtMillis: publishedAtMillis,
  );
}
