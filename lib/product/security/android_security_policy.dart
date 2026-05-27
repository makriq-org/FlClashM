import 'package:flclashx/models/models.dart';

class AndroidSecurityPolicy {
  const AndroidSecurityPolicy();

  static const ignoredProviderHint = 'flclashx-androidsecure';

  ClashConfig applyToPatchConfig(ClashConfig patchConfig) =>
      patchConfig.copyWith.tun(enable: true);

  void applyToRawConfig(
    Map<String, dynamic> rawConfig, {
    required ClashConfig patchConfig,
  }) {
    rawConfig["tun"] ??= <String, dynamic>{};
    rawConfig["tun"]["enable"] = true;
    rawConfig["tun"]["device"] = patchConfig.tun.device;
    rawConfig["tun"]["dns-hijack"] = patchConfig.tun.dnsHijack;
    rawConfig["tun"]["stack"] = patchConfig.tun.stack.name;
    rawConfig["tun"]["route-address"] = patchConfig.tun.routeAddress;
    rawConfig["tun"]["auto-route"] = patchConfig.tun.autoRoute;
  }
}

const androidSecurityPolicy = AndroidSecurityPolicy();
