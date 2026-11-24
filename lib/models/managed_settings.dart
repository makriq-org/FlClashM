import 'dart:convert';

import '../enum/enum.dart';

import 'clash_config.dart';
import 'provider_headers.dart';

/// Flags of `flclashx-settings` and the app switch each one drives.
const appSwitchSettings = {
  'minimize': 'app.minimizeOnExit',
  'autorun': 'app.autoLaunch',
  'shadowstart': 'app.silentLaunch',
  'autostart': 'app.autoRun',
  'autoupdate': 'app.autoCheckUpdate',
  'openlogs': 'app.openLogs',
  'closeconnections': 'app.closeConnections',
};

/// Driven by `flclashx-special: hideip`.
const hideIpSetting = 'app.hideIp';

/// Driven by `flclashx-special: novibrate`.
const vibrationSetting = 'app.vibration';

/// Cards the user arranged; `flclashx-widgets` replaces them only under
/// `denywidgets` or once the settings go back to the subscription.
const dashboardWidgetsSetting = 'app.dashboardWidgets';

/// The config keys a subscription takes over and the user may take back.
const managedClashKeys = {
  'mixed-port',
  'port',
  'socks-port',
  'redir-port',
  'tproxy-port',
  'allow-lan',
  'authentication',
  'ipv6',
  'log-level',
  'find-process-mode',
  'interface-name',
  'routing-mark',
  'tcp-concurrent',
  'unified-delay',
  'keep-alive-interval',
  'keep-alive-idle',
  'disable-keep-alive',
  'external-controller',
  'secret',
  'geodata-loader',
  'geo-auto-update',
  'geo-update-interval',
  'geox-url',
  'global-ua',
  'tun.device',
  'tun.stack',
  'tun.route-address',
  'tun.route-exclude-address',
  'tun.app-isolation',
};

String clashSettingKey(String yamlKey) => 'clash.$yamlKey';

/// Profile package rules and the manual Android VPN list are one setting.
const accessControlSettingKey = 'vpn.access-control';

/// The lockable keys of each settings page, for its hint.
const generalPageKeys = {
  'app.minimizeOnExit',
  'app.autoLaunch',
  'app.silentLaunch',
  'app.autoRun',
  'app.autoCheckUpdate',
  'app.openLogs',
  'app.closeConnections',
  'clash.allow-lan',
  'clash.authentication',
  'clash.ipv6',
  'clash.find-process-mode',
  'clash.tcp-concurrent',
  'clash.unified-delay',
  'clash.geodata-loader',
  'clash.external-controller',
  'clash.secret',
  'clash.log-level',
  'clash.mixed-port',
};

const networkPageKeys = {
  'clash.tun.stack',
  'clash.tun.app-isolation',
  'clash.interface-name',
  'clash.disable-keep-alive',
  'clash.keep-alive-idle',
  'clash.keep-alive-interval',
  'clash.routing-mark',
  'clash.tun.route-address',
  'clash.tun.route-exclude-address',
};

const themePageKeys = {
  'view.app.theme',
  'view.app.navbar',
  'view.app.tabs',
  'view.app.glass',
  'view.app.color',
  'view.app.black',
  hideIpSetting,
};

const proxiesPageKeys = {
  'view.proxies.type',
  'view.proxies.sort',
  'view.proxies.layout',
  'view.proxies.icon',
  'view.proxies.card',
  'view.proxies.hidetimeout',
};

/// The settings a `flclashx-view` header speaks for, by what it names.
Set<String> managedViewKeysOf(ViewRequest? view) {
  if (view == null) {
    return const {};
  }
  return {
    if (view.type != null) 'view.proxies.type',
    if (view.sort != null) 'view.proxies.sort',
    if (view.layout != null) 'view.proxies.layout',
    if (view.icon != null) 'view.proxies.icon',
    if (view.card != null) 'view.proxies.card',
    if (view.hideTimeout != null) 'view.proxies.hidetimeout',
    if (view.themeMode != null) 'view.app.theme',
    if (view.floatingNavigationBar != null) 'view.app.navbar',
    if (view.tabAnimation != null) 'view.app.tabs',
    if (view.liquidGlass != null) 'view.app.glass',
    if (view.color != null || view.colorStyle != null) 'view.app.color',
    if (view.pureBlack != null) 'view.app.black',
  };
}

Set<String> managedClashKeysOf(Iterable<String> present) => {
  for (final key in present)
    if (managedClashKeys.contains(key)) clashSettingKey(key),
};

/// [synced] with every setting in [owned] put back as [current] had it.
PatchClashConfig keepOwnedSettings(
  PatchClashConfig current,
  PatchClashConfig synced,
  Set<String> owned,
) {
  var next = synced;
  for (final key in owned) {
    next = switch (key) {
      'clash.mixed-port' => next.copyWith(mixedPort: current.mixedPort),
      'clash.port' => next.copyWith(port: current.port),
      'clash.socks-port' => next.copyWith(socksPort: current.socksPort),
      'clash.redir-port' => next.copyWith(redirPort: current.redirPort),
      'clash.tproxy-port' => next.copyWith(tproxyPort: current.tproxyPort),
      'clash.allow-lan' => next.copyWith(allowLan: current.allowLan),
      'clash.ipv6' => next.copyWith(ipv6: current.ipv6),
      'clash.log-level' => next.copyWith(logLevel: current.logLevel),
      'clash.find-process-mode' => next.copyWith(
        findProcessMode: current.findProcessMode,
      ),
      'clash.interface-name' => next.copyWith(
        interfaceNameMode: current.interfaceNameMode,
        interfaceName: current.interfaceName,
      ),
      'clash.routing-mark' => next.copyWith(routingMark: current.routingMark),
      'clash.tcp-concurrent' => next.copyWith(
        tcpConcurrent: current.tcpConcurrent,
      ),
      'clash.unified-delay' => next.copyWith(
        unifiedDelay: current.unifiedDelay,
      ),
      'clash.keep-alive-interval' => next.copyWith(
        keepAliveInterval: current.keepAliveInterval,
      ),
      'clash.keep-alive-idle' => next.copyWith(
        keepAliveIdle: current.keepAliveIdle,
      ),
      'clash.disable-keep-alive' => next.copyWith(
        disableKeepAlive: current.disableKeepAlive,
      ),
      'clash.external-controller' => next.copyWith(
        externalController: current.externalController,
      ),
      'clash.secret' => next.copyWith(secret: current.secret),
      'clash.geodata-loader' => next.copyWith(
        geodataLoader: current.geodataLoader,
      ),
      'clash.geo-auto-update' => next.copyWith(
        geoAutoUpdate: current.geoAutoUpdate,
      ),
      'clash.geo-update-interval' => next.copyWith(
        geoUpdateInterval: current.geoUpdateInterval,
      ),
      'clash.geox-url' => next.copyWith(geoXUrl: current.geoXUrl),
      'clash.global-ua' => next.copyWith(globalUa: current.globalUa),
      'clash.tun.device' => next.copyWith(
        tun: next.tun.copyWith(device: current.tun.device),
      ),
      'clash.tun.stack' => next.copyWith(
        tun: next.tun.copyWith(stack: current.tun.stack),
      ),
      'clash.tun.route-address' => next.copyWith(
        tun: next.tun.copyWith(routeAddress: current.tun.routeAddress),
      ),
      'clash.tun.route-exclude-address' => next.copyWith(
        tun: next.tun.copyWith(
          routeExcludeAddress: current.tun.routeExcludeAddress,
        ),
      ),
      'clash.tun.app-isolation' => next.copyWith(
        tun: next.tun.copyWith(appIsolation: current.tun.appIsolation),
      ),
      _ => next,
    };
  }
  return next;
}


/// One parsed `appIsolation` block from the live Go VPN options. The row and
/// its status line share it so both name the mode the guard actually uses.
class AppliedAppIsolation {
  const AppliedAppIsolation({
    required this.mode,
    required this.source,
    required this.status,
    required this.detail,
  });

  final AppIsolationMode? mode;
  final String source;
  final String status;
  final String detail;

  static AppliedAppIsolation? parse(String raw) {
    try {
      final options = jsonDecode(raw) as Map<String, dynamic>;
      final value = options['appIsolation'];
      if (value is! Map) {
        return null;
      }
      final mode = value['mode'];
      return AppliedAppIsolation(
        mode: mode is String
            ? AppIsolationMode.values.asNameMap()[mode]
            : null,
        source: value['source'] is String
            ? value['source'] as String
            : 'default',
        status: value['status'] is String ? value['status'] as String : '',
        detail: value['detail'] is String ? value['detail'] as String : '',
      );
    } catch (_) {
      return null;
    }
  }
}


/// Row value for app isolation. The profile's effective mode wins only while
/// the subscription actually owns it; otherwise the local setting is shown.
AppIsolationMode effectiveAppIsolationMode({
  required bool locked,
  required AppliedAppIsolation? applied,
  required AppIsolationMode local,
}) {
  if (locked && applied?.source == 'profile' && applied?.mode != null) {
    return applied!.mode!;
  }
  return local;
}
