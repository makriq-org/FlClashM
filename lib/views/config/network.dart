import 'dart:io';

import 'package:flclashx/clash/clash.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/features/form/form.dart';
import 'package:flclashx/l10n/l10n.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/config.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/views/config/override.dart';
import 'package:flclashx/views/config/tun.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' show dirname, join;

typedef _VpnUpdate<T> = VpnProps Function(VpnProps state, T value);

typedef _NetworkUpdate<T> = NetworkProps Function(NetworkProps state, T value);

typedef _TunUpdate<T> =
    PatchClashConfig Function(PatchClashConfig state, T value);

ConfigWriter<T> _vpnWriter<T>(_VpnUpdate<T> update) {
  return (ref, value) => ref
      .read(vpnSettingProvider.notifier)
      .update((state) => update(state, value));
}

ConfigWriter<T> _networkWriter<T>(_NetworkUpdate<T> update) {
  return (ref, value) => ref
      .read(networkSettingProvider.notifier)
      .update((state) => update(state, value));
}

ConfigWriter<T> _tunWriter<T>(_TunUpdate<T> update) {
  return (ref, value) => ref
      .read(patchClashConfigProvider.notifier)
      .update((state) => update(state, value));
}

ConfigToggleItem _vpnToggle({
  required ConfigLabel title,
  required bool Function(VpnProps state) select,
  required _VpnUpdate<bool> update,
}) {
  return ConfigToggleItem(
    title: title,
    selector: vpnSettingProvider.select(select),
    onChanged: _vpnWriter(update),
  );
}

ConfigToggleItem _networkToggle({
  required ConfigLabel title,
  required bool Function(NetworkProps state) select,
  required _NetworkUpdate<bool> update,
}) {
  return ConfigToggleItem(
    title: title,
    selector: networkSettingProvider.select(select),
    onChanged: _networkWriter(update),
  );
}

class VPNItem extends ConsumerWidget {
  const VPNItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    return _vpnToggle(
      title: (l) => 'VPN',
      select: (state) => state.enable,
      update: (state, value) => state.copyWith(enable: value),
    );
  }
}

class TUNItem extends ConsumerWidget {
  const TUNItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    return ConfigToggleItem(
      title: (l) => l.tun,
      selector: patchClashConfigProvider.select((state) => state.tun.enable),
      onChanged: _tunWriter(
        (state, value) => state.copyWith.tun(enable: value),
      ),
    );
  }
}

class AllowBypassItem extends ConsumerWidget {
  const AllowBypassItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    return _vpnToggle(
      title: (l) => l.allowBypass,
      select: (state) => state.allowBypass,
      update: (state, value) => state.copyWith(allowBypass: value),
    );
  }
}

class VpnSystemProxyItem extends ConsumerWidget {
  const VpnSystemProxyItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    if (!ref.watch(systemProxyAllowedProvider)) {
      return const _LockedSystemProxyItem();
    }
    return _vpnToggle(
      title: (l) => l.systemProxy,
      select: (state) => state.systemProxy,
      update: (state, value) => state.copyWith(systemProxy: value),
    );
  }
}

class SystemProxyItem extends ConsumerWidget {
  const SystemProxyItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    if (!ref.watch(systemProxyAllowedProvider)) {
      return const _LockedSystemProxyItem();
    }
    return _networkToggle(
      title: (l) => l.systemProxy,
      select: (state) => state.systemProxy,
      update: (state, value) => state.copyWith(systemProxy: value),
    );
  }
}

/// Under the panel's onlytun, which leaves TUN as the only takeover.
class _LockedSystemProxyItem extends StatelessWidget {
  const _LockedSystemProxyItem();

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return ListItem.toggle(
      title: Text(appLocalizations.systemProxy),
      subtitle: Text(appLocalizations.managedByProvider),
      value: false,
    );
  }
}

class Ipv6Item extends ConsumerWidget {
  const Ipv6Item({super.key});

  @override
  Widget build(BuildContext context, ref) {
    return _vpnToggle(
      title: (l) => 'IPv6',
      select: (state) => state.ipv6,
      update: (state, value) => state.copyWith(ipv6: value),
    );
  }
}

class AutoSetSystemDnsItem extends ConsumerWidget {
  const AutoSetSystemDnsItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    return _networkToggle(
      title: (l) => l.autoSetSystemDns,
      select: (state) => state.autoSetSystemDns,
      update: (state, value) => state.copyWith(autoSetSystemDns: value),
    );
  }
}

class DNSHijackingItem extends ConsumerWidget {
  const DNSHijackingItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    return _vpnToggle(
      title: (l) => l.dnsHijacking,
      select: (state) => state.dnsHijacking,
      update: (state, value) => state.copyWith(dnsHijacking: value),
    );
  }
}

String _appIsolationLabel(AppLocalizations l, AppIsolationMode mode) =>
    switch (mode) {
      AppIsolationMode.off => l.appIsolationOff,
      AppIsolationMode.balanced => l.appIsolationBalanced,
      AppIsolationMode.strict => l.appIsolationStrict,
    };

const appIsolationSettingKey = 'clash.tun.app-isolation';

/// The live `appIsolation` block from Go, shared by the row and its status.
final appliedAppIsolationProvider =
    FutureProvider.autoDispose<AppliedAppIsolation?>((ref) async {
      // Re-read when the VPN starts, the saved mode changes or a profile
      // switch changes which settings the subscription owns.
      ref.watch(isStartProvider);
      ref.watch(managedSettingsProvider);
      ref.watch(
        currentProfileProvider.select((profile) => profile?.lastUpdateDate),
      );
      ref.watch(
        patchClashConfigProvider.select((state) => state.tun.appIsolation),
      );
      final raw =
          await (clashLib?.readAndroidVpnOptions() ?? Future.value(''));
      return AppliedAppIsolation.parse(raw);
    });

/// The value the row shows. While the subscription owns the mode, Go's
/// effective mode is authoritative; otherwise the local setting is.
final appIsolationViewProvider = Provider<AppIsolationMode>((ref) {
  return effectiveAppIsolationMode(
    locked: ref.watch(settingLockedProvider(appIsolationSettingKey)),
    applied: ref.watch(appliedAppIsolationProvider).value,
    local: ref.watch(
      patchClashConfigProvider.select((state) => state.tun.appIsolation),
    ),
  );
});

class AppIsolationItem extends ConsumerWidget {
  const AppIsolationItem({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    return ManagedSetting(
      settingKey: appIsolationSettingKey,
      // Taking the setting over must keep the mode that is actually applied.
      onTakenOver: () {
        final mode = ref.read(appIsolationViewProvider);
        ref
            .read(patchClashConfigProvider.notifier)
            .update((state) => state.copyWith.tun(appIsolation: mode));
      },
      child: ConfigOptionsItem<AppIsolationMode>(
        title: (l) => l.appIsolation,
        options: AppIsolationMode.values,
        textBuilder: (mode) => _appIsolationLabel(appLocalizations, mode),
        selector: appIsolationViewProvider,
        onChanged: _tunWriter(
          (state, value) => state.copyWith.tun(appIsolation: value),
        ),
      ),
    );
  }
}

/// Shows the mode the guard actually uses and warns when it cannot be applied
/// in full. Both the mode and the status come from Go.
class AppIsolationStatus extends ConsumerWidget {
  const AppIsolationStatus({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(appliedAppIsolationProvider).value;
    if (status == null) {
      return const SizedBox.shrink();
    }
    final appLocalizations = context.appLocalizations;
    final warning =
        status.status == 'unavailable' ||
        status.status == 'degraded' ||
        status.status == 'limited';
    final lines = <String>[
      if (status.status != 'inactive')
        '${appLocalizations.appIsolationApplied}: '
            '${_appIsolationLabel(appLocalizations, status.mode ?? AppIsolationMode.balanced)} '
            '(${_sourceLabel(appLocalizations, status.source)})',
      if (status.status == 'limited') appLocalizations.appIsolationLimited,
      if (status.status == 'degraded')
        [
          appLocalizations.appIsolationDegraded,
          if (status.detail.isNotEmpty) status.detail,
        ].join(' '),
      if (status.status == 'unavailable')
        [
          appLocalizations.appIsolationUnavailable,
          if (status.detail.isNotEmpty) status.detail,
        ].join(' '),
      if (status.status == 'inactive') appLocalizations.appIsolationInactive,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Text(
        lines.join('\n'),
        style: warning
            ? context.listCaptionStyle.copyWith(
                color: context.colorScheme.error,
              )
            : context.listCaptionStyle,
      ),
    );
  }
}

String _sourceLabel(AppLocalizations l, String source) => switch (source) {
  'profile' => l.appIsolationSourceProfile,
  'user' => l.appIsolationSourceUser,
  _ => l.appIsolationSourceDefault,
};

class TunStackItem extends ConsumerWidget {
  const TunStackItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    return ConfigOptionsItem<TunStack>(
      managedKey: 'clash.tun.stack',
      title: (l) => l.stackMode,
      options: TunStack.values,
      textBuilder: (stack) => stack.name,
      selector: patchClashConfigProvider.select((state) => state.tun.stack),
      onChanged: _tunWriter((state, value) => state.copyWith.tun(stack: value)),
    );
  }
}

class InterfaceNameModeItem extends ConsumerWidget {
  const InterfaceNameModeItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    return ConfigOptionsItem<InterfaceNameMode>(
      managedKey: 'clash.interface-name',
      title: (l) => l.interfaceNameMode,
      options: InterfaceNameMode.values,
      textBuilder: (mode) => switch (mode) {
        InterfaceNameMode.clear => appLocalizations.interfaceNameModeClear,
        InterfaceNameMode.follow => appLocalizations.interfaceNameModeFollow,
        InterfaceNameMode.custom => appLocalizations.interfaceNameModeCustom,
      },
      selector: patchClashConfigProvider.select(
        (state) => state.interfaceNameMode,
      ),
      onChanged: _tunWriter(
        (state, value) => state.copyWith(interfaceNameMode: value),
      ),
    );
  }
}

class InterfaceNameItem extends ConsumerWidget {
  const InterfaceNameItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    return ConfigTextItem(
      managedKey: 'clash.interface-name',
      title: (l) => l.interfaceName,
      maxLength: TextInputLimits.name,
      selector: patchClashConfigProvider.select((state) => state.interfaceName),
      onChanged: _tunWriter(
        (state, value) => state.copyWith(interfaceName: value.trim()),
      ),
    );
  }
}

class BypassPrivateRouteItem extends ConsumerWidget {
  const BypassPrivateRouteItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    return _networkToggle(
      title: (l) => l.bypassPrivateRoute,
      select: (state) => state.bypassPrivateRoute,
      update: (state, value) => state.copyWith(bypassPrivateRoute: value),
    );
  }
}

class BypassDomainItem extends ConsumerWidget {
  const BypassDomainItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    return ConfigListEditItem(
      title: (l) => l.bypassDomain,
      itemMaxLength: TextInputLimits.domain,
      selector: networkSettingProvider.select((state) => state.bypassDomain),
      onChanged: _networkWriter(
        (state, value) => state.copyWith(bypassDomain: value),
      ),
    );
  }
}

class RouteAddressItem extends ConsumerWidget {
  const RouteAddressItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    return ManagedSetting(
      settingKey: 'clash.tun.route-address',
      child: ConfigListEditItem(
        title: (l) => l.routeAddress,
        itemMaxLength: TextInputLimits.cidr,
        itemValidator: validateCidr,
        selector: patchClashConfigProvider.select(
          (state) => state.tun.routeAddress,
        ),
        onChanged: _tunWriter(
          (state, value) => state.copyWith.tun(routeAddress: value),
        ),
      ),
    );
  }
}

class LoopbackItem extends StatelessWidget {
  const LoopbackItem({super.key});

  @override
  Widget build(BuildContext context) {
    return ListItem(
      title: Text(context.appLocalizations.loopback),
      onTap: () {
        windows?.runas(
          '"${join(dirname(Platform.resolvedExecutable), "EnableLoopback.exe")}"',
          '',
        );
      },
    );
  }
}

const _maxUint32 = 0xFFFFFFFF;

class _NumberItem extends ConsumerWidget {
  const _NumberItem({
    required this.title,
    required this.select,
    required this.update,
    this.isSeconds = false,
    this.min = 0,
    this.max = _maxUint32,
    this.managedKey,
  });

  final ConfigLabel title;
  final String? managedKey;
  final int Function(PatchClashConfig state) select;
  final _TunUpdate<int> update;
  final bool isSeconds;
  final int min;
  final int max;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final label = title(appLocalizations);
    final value = ref.watch(patchClashConfigProvider.select(select));
    final item = ListItem.input(
      title: Text(label),
      subtitle: Text(
        isSeconds ? appLocalizations.secondsCount(value) : '$value',
      ),
      dialogTitle: label,
      value: '$value',
      resetValue: '${select(defaultClashConfig)}',
      suffixText: isSeconds ? appLocalizations.seconds : null,
      maxLength: TextInputLimits.number,
      keyboardType: TextInputType.number,
      validator: (value) {
        final number = int.tryParse(value?.trim() ?? '');
        if (number == null) {
          return appLocalizations.numberTip(label);
        }
        return number < min || number > max
            ? appLocalizations.numberRangeTip(label, '$min', '$max')
            : null;
      },
      onChanged: (value) {
        if (value == null) {
          return;
        }
        ref
            .read(patchClashConfigProvider.notifier)
            .update((state) => update(state, int.parse(value.trim())));
      },
    );
    final managedKey = this.managedKey;
    return managedKey == null
        ? item
        : ManagedSetting(settingKey: managedKey, child: item);
  }
}

// Android's VPN service starts from these rows; the desktop TUN takes the
// same keys as overrides, so a profile's own values apply unless picked.
List<Widget> tunItems({required bool isMipsStack}) {
  return [
    _NumberItem(
      title: (l) => 'MTU',
      min: minTunMtu,
      max: maxTunMtu,
      select: (state) => state.tun.mtu,
      update: (state, value) => state.copyWith.tun(mtu: value),
    ),
    if (isMipsStack)
      ConfigOptionsItem<String>(
        title: (l) => l.congestionController,
        options: congestionControllers,
        textBuilder: (value) => value,
        selector: patchClashConfigProvider.select(
          (state) => state.tun.congestionController,
        ),
        onChanged: _tunWriter(
          (state, value) => state.copyWith.tun(congestionController: value),
        ),
      ),
    const BypassPrivateRouteItem(),
    const RouteAddressItem(),
    ManagedSetting(
      settingKey: 'clash.tun.route-exclude-address',
      child: ConfigListEditItem(
        title: (l) => l.routeExcludeAddress,
        itemMaxLength: TextInputLimits.cidr,
        itemValidator: validateCidr,
        selector: patchClashConfigProvider.select(
          (state) => state.tun.routeExcludeAddress,
        ),
        onChanged: _tunWriter(
          (state, value) => state.copyWith.tun(routeExcludeAddress: value),
        ),
      ),
    ),
  ];
}

class TunSection extends ConsumerWidget {
  const TunSection({
    super.key,
    required this.isDesktop,
    required this.isLinux,
    required this.isWindows,
  });

  final bool isDesktop;
  final bool isLinux;
  final bool isWindows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    if (!isDesktop) {
      final isMipsStack = ref.watch(
        patchClashConfigProvider.select(
          (state) => state.tun.stack == TunStack.mips,
        ),
      );
      return generateSection(
        title: appLocalizations.tun,
        items: tunItems(isMipsStack: isMipsStack),
        footer: appLocalizations.bypassPrivateRouteDesc,
      );
    }
    final spec = appTunOverrideSpec(isLinux: isLinux, isWindows: isWindows);
    final picked = ref.watch(
      patchClashConfigProvider.select((state) => state.tunOverrideKeys),
    );
    final listed = [
      for (final key in spec.values)
        if (picked.contains(key)) key,
    ];
    void handleAdd() => showOverrideAddSheet(context, ref, spec);
    return generateAnimatedSection(
      title: appLocalizations.tun,
      items: [
        const BypassPrivateRouteItem(key: ValueKey(#bypassPrivateRoute)),
        for (final key in listed)
          OverrideEntry(key: ValueKey(key), spec: spec, overrideKey: key),
        if (listed.length < spec.values.length)
          FormRow(
            key: const ValueKey(#add),
            leading: EntryButton.add(onPressed: handleAdd),
            title: spec.target.addEntry(appLocalizations),
            titleStyle: TextStyle(color: context.colorScheme.primary),
            onPressed: handleAdd,
          ),
      ],
      footer: [
        appLocalizations.bypassPrivateRouteDesc,
        appLocalizations.tunOverrideDesc,
        ?spec.footerOf(listed, appLocalizations),
      ].join('\n'),
    );
  }
}

// mihomo keeps TCP keep-alive off on Android whatever the config says
// (component/keepalive), and only Linux honours a routing mark.
List<Widget> outboundItems({required bool isDesktop, required bool isLinux}) {
  return [
    if (isDesktop) ...[
      ConfigToggleItem(
        title: (l) => l.disableKeepAlive,
        managedKey: 'clash.disable-keep-alive',
        selector: patchClashConfigProvider.select(
          (state) => state.disableKeepAlive,
        ),
        onChanged: _tunWriter(
          (state, value) => state.copyWith(disableKeepAlive: value),
        ),
      ),
      _NumberItem(
        title: (l) => l.keepAliveIdle,
        managedKey: 'clash.keep-alive-idle',
        isSeconds: true,
        select: (state) => state.keepAliveIdle,
        update: (state, value) => state.copyWith(keepAliveIdle: value),
      ),
      _NumberItem(
        title: (l) => l.keepAliveIntervalDesc,
        managedKey: 'clash.keep-alive-interval',
        isSeconds: true,
        select: (state) => state.keepAliveInterval,
        update: (state, value) => state.copyWith(keepAliveInterval: value),
      ),
    ],
    if (isLinux)
      _NumberItem(
        title: (l) => l.routingMark,
        managedKey: 'clash.routing-mark',
        select: (state) => state.routingMark,
        update: (state, value) => state.copyWith(routingMark: value),
      ),
  ];
}

List<Widget> networkOptionsItems({
  required bool isDesktop,
  required bool isMacOS,
  required bool isCustomInterfaceName,
}) {
  return [
    if (isDesktop) const TUNItem(),
    if (isMacOS) const AutoSetSystemDnsItem(),
    const TunStackItem(),
    // mihomo's DefaultSocketHook ignores interface-name on Android
    // (core/lib.go installHooks, vendored dialer.go), so these rows only
    // apply on desktop.
    if (isDesktop) ...[
      const InterfaceNameModeItem(),
      if (isCustomInterfaceName) const InterfaceNameItem(),
    ],
  ];
}

class VpnSections extends ConsumerWidget {
  const VpnSections({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final authenticationEnable = ref.watch(
      networkSettingProvider.select((state) => state.authentication.enable),
    );
    return Column(
      children: [
        generateSection(
          items: const [VPNItem()],
          footer: appLocalizations.vpnEnableDesc,
        ),
        generateSection(
          title: 'VPN',
          items: const [
            VpnSystemProxyItem(),
            BypassDomainItem(),
            AllowBypassItem(),
            Ipv6Item(),
            DNSHijackingItem(),
          ],
          footer: [
            if (authenticationEnable)
              appLocalizations.authenticationSystemProxyDesc,
            appLocalizations.bypassDomainDesc,
            appLocalizations.ipv6InboundDesc,
          ].join('\n'),
        ),
        generateSection(
          title: appLocalizations.appIsolation,
          items: const [AppIsolationItem()],
          footer: [
            appLocalizations.appIsolationDesc,
            '${appLocalizations.appIsolationOff}: ${appLocalizations.appIsolationOffDesc}',
            '${appLocalizations.appIsolationBalanced}: ${appLocalizations.appIsolationBalancedDesc}',
            '${appLocalizations.appIsolationStrict}: ${appLocalizations.appIsolationStrictDesc}',
          ].join('\n'),
        ),
        const AppIsolationStatus(),
      ],
    );
  }
}

class SystemProxySection extends StatelessWidget {
  const SystemProxySection({super.key});

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return generateSection(
      title: appLocalizations.system,
      items: [
        const SystemProxyItem(),
        const BypassDomainItem(),
        if (system.isWindows) const LoopbackItem(),
      ],
      footer: appLocalizations.bypassDomainDesc,
    );
  }
}

class NetworkOptionsSection extends ConsumerWidget {
  const NetworkOptionsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCustomInterfaceName = ref.watch(
      patchClashConfigProvider.select(
        (state) => state.interfaceNameMode == InterfaceNameMode.custom,
      ),
    );
    final appLocalizations = context.appLocalizations;
    final footer = [
      if (system.isDesktop) ...[
        appLocalizations.tunDesc,
        if (isCustomInterfaceName) appLocalizations.interfaceNameDesc,
      ],
    ];
    return generateSection(
      title: appLocalizations.options,
      items: networkOptionsItems(
        isDesktop: system.isDesktop,
        isMacOS: system.isMacOS,
        isCustomInterfaceName: isCustomInterfaceName,
      ),
      footer: footer.isEmpty ? null : footer.join('\n'),
    );
  }
}

class NetworkListView extends StatelessWidget {
  const NetworkListView({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: 16,
      ).copyWith(top: context.contentTopPadding, bottom: 16),
      children: [
        const ManagedSettingsHint(keys: networkPageKeys),
        if (system.isAndroid) const VpnSections(),
        if (system.isDesktop) const SystemProxySection(),
        const NetworkOptionsSection(),
        TunSection(
          isDesktop: system.isDesktop,
          isLinux: system.isLinux,
          isWindows: system.isWindows,
        ),
        generateSection(
          title: context.appLocalizations.outbound,
          items: outboundItems(
            isDesktop: system.isDesktop,
            isLinux: system.isLinux,
          ),
        ),
      ],
    );
  }
}
