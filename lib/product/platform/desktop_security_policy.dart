import 'dart:io';

import 'package:flclashx/models/models.dart';

import '../compile/runtime_plan.dart';
import '../runtime/desktop_runtime_layout.dart';
import '../security/security_policy.dart';
import 'product_install_layout.dart';

/// Desktop has no Android socket exposure policy. It preserves the compiled
/// profile unchanged until desktop runtime policy is introduced.
class DesktopSecurityPolicy implements SecurityPolicy {
  const DesktopSecurityPolicy({
    this.processPaths = const [],
    this.helperOwnsRoutes = false,
  });

  factory DesktopSecurityPolicy.currentInstall() {
    final layout = DesktopRuntimeLayout.current();
    return DesktopSecurityPolicy(
      helperOwnsRoutes: Platform.isMacOS,
      processPaths: [
        layout.artifactPath(ProductInstallLayout.mihomoArtifact),
        for (final artifact in const [
          ProductInstallLayout.naiveproxyArtifact,
          ProductInstallLayout.olcrtcArtifact,
          ProductInstallLayout.byedpiArtifact,
          ProductInstallLayout.stormdnsArtifact,
        ])
          layout.artifactPath(artifact),
      ],
    );
  }

  final List<String> processPaths;
  final bool helperOwnsRoutes;

  @override
  ClashConfig securePatchConfig({
    required ClashConfig patchConfig,
    required SecurityPolicyContext context,
  }) =>
      _secure(patchConfig);

  @override
  UpdateParams secureRuntimeUpdate({
    required UpdateParams updateParams,
    required SecurityPolicyContext context,
  }) =>
      helperOwnsRoutes && updateParams.tun.enable
          ? updateParams.copyWith(
              tun: updateParams.tun.copyWith(autoRoute: false),
            )
          : updateParams;

  @override
  SecuredProfilePatch secureProfile({
    required CompiledProfilePatch compiledProfile,
    required SecurityPolicyContext context,
  }) =>
      SecuredProfilePatch(
        patchConfig: _secure(compiledProfile.patchConfig),
        metadata: compiledProfile.metadata,
      );

  ClashConfig _secure(ClashConfig config) {
    if (!config.tun.enable) return config;
    final loopRules = [
      for (final processPath in processPaths)
        'PROCESS-PATH,$processPath,DIRECT',
    ];
    return config.copyWith(
      tun:
          helperOwnsRoutes ? config.tun.copyWith(autoRoute: false) : config.tun,
      rule: [
        ...loopRules,
        for (final rule in config.rule)
          if (!loopRules.contains(rule)) rule,
      ],
    );
  }
}
