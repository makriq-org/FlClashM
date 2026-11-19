import 'package:shared_preferences/shared_preferences.dart';

/// Помнит, какой APK подготовлен к установке. Благодаря этой записи скачанные
/// файлы удаляются только после подтверждённого обновления: пока установленная
/// сборка старше подготовленной, APK остаётся для повтора.
abstract interface class AppUpdateInstallJournal {
  Future<int?> readPreparedVersionCode();

  Future<void> recordPrepared(int versionCode);

  Future<void> clear();
}

class SharedPreferencesAppUpdateInstallJournal
    implements AppUpdateInstallJournal {
  const SharedPreferencesAppUpdateInstallJournal();

  static const _key = 'flclashm.appUpdate.preparedVersionCode';

  @override
  Future<int?> readPreparedVersionCode() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getInt(_key);
    return raw != null && raw > 0 ? raw : null;
  }

  @override
  Future<void> recordPrepared(int versionCode) async {
    if (versionCode <= 0) {
      throw const FormatException('Invalid prepared app update version code.');
    }
    final preferences = await SharedPreferences.getInstance();
    final stored = await preferences.setInt(_key, versionCode);
    if (!stored) {
      throw StateError('Unable to persist the prepared app update version.');
    }
  }

  @override
  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_key);
  }
}

/// Обновление состоялось: установленная сборка не старше подготовленной.
bool isPreparedAppUpdateInstalled({
  required int? preparedVersionCode,
  required int? installedVersionCode,
}) {
  if (preparedVersionCode == null || installedVersionCode == null) {
    return false;
  }
  return installedVersionCode >= preparedVersionCode;
}
