import 'package:flutter/foundation.dart';

import '../../common/common.dart';
import '../../enum/enum.dart';
import '../../models/models.dart';
import '../runtime/vpn_access_control.dart';

/// Where the access control that is applied to the tunnel comes from.
enum TunnelAccessSource {
  /// The active profile configures split tunneling (`tun.include-package` /
  /// `tun.exclude-package`), which overrides the manual settings.
  profile,

  /// The user's manual access control settings drive the tunnel.
  manual,
}

/// A read-only snapshot of what the *running* core reports for the tunnel.
///
/// [appliedEnabled]/[appliedMode]/[appliedPackages] mirror
/// `AndroidVpnOptions.accessControl`, which the core fills from
/// `CoreState.vpnProps.accessControl` — i.e. the already hardened access
/// control (see [enforceSelfPackageBypass]). That makes it the ground truth of
/// what is actually enforced on the tunnel right now.
///
/// [includePackages]/[excludePackages] mirror the core's
/// `tun.include-package` / `tun.exclude-package`, i.e. the config-declared
/// split tunneling before the self-package bypass is layered on.
@immutable
class TunnelAccessObservation {
  TunnelAccessObservation({
    required this.appliedEnabled,
    required this.appliedMode,
    required List<String> appliedPackages,
    required List<String> includePackages,
    required List<String> excludePackages,
  })  : appliedPackages = List.unmodifiable(appliedPackages),
        includePackages = List.unmodifiable(includePackages),
        excludePackages = List.unmodifiable(excludePackages);

  factory TunnelAccessObservation.fromOptions(AndroidVpnOptions options) {
    final accessControl = options.accessControl;
    return TunnelAccessObservation(
      appliedEnabled: accessControl?.enable ?? false,
      appliedMode: accessControl?.mode ?? AccessControlMode.rejectSelected,
      appliedPackages: accessControl?.currentList ?? const [],
      includePackages: options.includePackage,
      excludePackages: options.excludePackage,
    );
  }

  final bool appliedEnabled;
  final AccessControlMode appliedMode;
  final List<String> appliedPackages;
  final List<String> includePackages;
  final List<String> excludePackages;
}

/// What is *actually* included in / excluded from the VPN tunnel.
///
/// The [effectivePackages]/[mode]/[enabled] fields are computed through the
/// exact same [enforceSelfPackageBypass] pass the runtime uses when it builds
/// the core state, so this report reflects reality — not just the raw config.
@immutable
class TunnelAccessReport {
  TunnelAccessReport({
    required this.enabled,
    required this.source,
    required this.mode,
    required List<String> configuredPackages,
    required List<String> effectivePackages,
    required List<String> selfBypassPackages,
    this.observation,
  })  : configuredPackages = List.unmodifiable(configuredPackages),
        effectivePackages = List.unmodifiable(effectivePackages),
        selfBypassPackages = List.unmodifiable(selfBypassPackages);

  /// Whether any access control is enforced on the tunnel. The runtime always
  /// enforces at least the self-package bypass, so this is effectively always
  /// true on Android.
  final bool enabled;

  /// Whether the profile config or the manual settings drive the tunnel.
  final TunnelAccessSource source;

  /// The effective mode after the self-package bypass is applied.
  final AccessControlMode mode;

  /// The config/manual package list before the self-package bypass.
  final List<String> configuredPackages;

  /// The package list actually handed to the platform VPN — the ground truth
  /// of what is included/excluded (self bypass included).
  final List<String> effectivePackages;

  /// The self package(s) the runtime force-bypasses out of the tunnel.
  final List<String> selfBypassPackages;

  /// A snapshot of the running core, or `null` when the tunnel is stopped or
  /// the options could not be read.
  final TunnelAccessObservation? observation;

  bool get isWhitelist => mode == AccessControlMode.acceptSelected;

  /// True when a live observation is available and what the running core
  /// actually enforces diverges from the computed effective access control —
  /// e.g. settings changed but the tunnel has not been restarted yet.
  bool get hasObservedDrift {
    final observation = this.observation;
    if (observation == null) {
      return false;
    }
    if (observation.appliedEnabled != enabled ||
        observation.appliedMode != mode) {
      return true;
    }
    return !setEquals(
      effectivePackages.toSet(),
      observation.appliedPackages.toSet(),
    );
  }
}

/// Resolves what is actually applied to the VPN tunnel so the Access Control
/// page can display it for diagnostics.
class TunnelAccessInspector {
  const TunnelAccessInspector();

  TunnelAccessReport inspect({
    required AccessControl manualAccessControl,
    AccessControl? profileAccessControl,
    AndroidVpnOptions? observedOptions,
    List<String> selfPackageNames = const [packageName, '$packageName.dev'],
  }) {
    final resolved = profileAccessControl ?? manualAccessControl;
    final hardened = enforceSelfPackageBypass(
      resolved,
      selfPackageNames: selfPackageNames,
    );
    final selfPackages = selfPackageNames
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toSet();
    final effectivePackages = hardened.currentList;
    final selfBypassPackages = effectivePackages
        .where(selfPackages.contains)
        .toList(growable: false);

    return TunnelAccessReport(
      enabled: hardened.enable,
      source: profileAccessControl != null
          ? TunnelAccessSource.profile
          : TunnelAccessSource.manual,
      mode: hardened.mode,
      configuredPackages: resolved.currentList,
      effectivePackages: effectivePackages,
      selfBypassPackages: selfBypassPackages,
      observation: observedOptions == null
          ? null
          : TunnelAccessObservation.fromOptions(observedOptions),
    );
  }
}
