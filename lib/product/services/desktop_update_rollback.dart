import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_update_catalog.dart';

abstract interface class DesktopUpdateRollbackGuard {
  Future<void> validateAndRecord(DesktopUpdateCatalog catalog);
}

class SharedPreferencesDesktopUpdateRollbackGuard
    implements DesktopUpdateRollbackGuard {
  const SharedPreferencesDesktopUpdateRollbackGuard();

  static const _keyPrefix = 'flclashm.desktopUpdate.highestCatalog';

  @override
  Future<void> validateAndRecord(DesktopUpdateCatalog catalog) async {
    final preferences = await SharedPreferences.getInstance();
    final key = '$_keyPrefix.${catalog.channel.wireName}.${catalog.catalogId}';
    final highest = _decode(preferences.getString(key));
    final publishedAt = catalog.publishedAt.millisecondsSinceEpoch;
    if (catalog.versionCode < highest.versionCode ||
        (catalog.versionCode == highest.versionCode &&
            publishedAt < highest.publishedAtMillis)) {
      throw const FormatException('Desktop update catalog rollback rejected.');
    }
    if (catalog.versionCode > highest.versionCode ||
        publishedAt > highest.publishedAtMillis) {
      if (!await preferences.setString(
        key,
        jsonEncode({
          'versionCode': catalog.versionCode,
          'publishedAtMillis': publishedAt,
        }),
      )) {
        throw StateError('Unable to persist desktop update rollback state.');
      }
    }
  }
}

({int versionCode, int publishedAtMillis}) _decode(String? raw) {
  if (raw == null) {
    return (versionCode: 0, publishedAtMillis: 0);
  }
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic> ||
      decoded['versionCode'] is! int ||
      decoded['publishedAtMillis'] is! int ||
      (decoded['versionCode'] as int) < 0 ||
      (decoded['publishedAtMillis'] as int) < 0) {
    throw const FormatException('Invalid desktop update rollback state.');
  }
  return (
    versionCode: decoded['versionCode'] as int,
    publishedAtMillis: decoded['publishedAtMillis'] as int,
  );
}
