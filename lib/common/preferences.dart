import '../models/models.dart';
import '../product/backend/backend.dart';
import '../product/backend/frontend_settings.dart';
import 'boot_record.dart';
import 'system_dns.dart';

/// Compatibility surface for UI settings. No SharedPreferences authority.
class Preferences {
  Future<bool> get isInit async => backendClient.attached;
  Future<void> rebind() => backendClient.refresh();
  Map<String,dynamic> get _settings => backendClient.settings;
  Future<int> getVersion() async => (_settings['version'] as num?)?.toInt() ?? 0;
  Future<void> setVersion(int version) async { await backendClient.command('settings.patch',{'patch':{'version':version}}); }
  Future<int> getUpgradeVersion() async => (_settings['upgradeVersion'] as num?)?.toInt() ?? 0;
  Future<void> setUpgradeVersion(int version) async { await backendClient.command('settings.patch',{'patch':{'upgradeVersion':version}}); }
  Future<Map<String,Object?>?> getConfigMap() async => frontendSettings(_settings);
  Future<Config?> getConfig() async => Config.fromJson(frontendSettings(_settings));
  Future<bool> saveConfig(Config config) async {
    if (!frontendSettingsStore.projecting) await frontendSettingsStore.save(config);
    return true;
  }
  Future<Map<String,Object?>?> getClashConfigMap() async => null;
  Future<void> clearClashConfig() async { await backendClient.command('settings.patch',{'patch':{'legacyClashConfig':null}}); }
  Future<void> saveShareState(SharedState state) async { throw StateError('Android shared state is projected by Go'); }
  Future<SystemDnsRecord?> getSystemDnsRecord() async {
    final value = _settings['systemDnsRecord'];
    return value is Map ? SystemDnsRecord.fromJson(Map<String,dynamic>.from(value)) : null;
  }
  Future<void> saveSystemDnsRecord(SystemDnsRecord record) async { await backendClient.command('settings.patch',{'patch':{'systemDnsRecord':record.toJson()}}); }
  Future<void> clearSystemDnsRecord() async { await backendClient.command('settings.patch',{'patch':{'systemDnsRecord':null}}); }
  Future<BootRecord?> getBootRecord() async {
    final value=_settings['bootRecord'];
    return value is Map ? BootRecord.fromJson(Map<String,dynamic>.from(value)) : null;
  }
  Future<void> saveBootRecord(BootRecord record) async { await backendClient.command('settings.patch',{'patch':{'bootRecord':record.toJson()}}); }
  Future<void> clearPreferences() async { await backendClient.command('data.reset'); }
}
final preferences=Preferences();
