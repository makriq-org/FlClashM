import 'package:flclashx/models/models.dart';

import '../compile/runtime_plan.dart';
import '../runtime/desktop_runtime_layout.dart';
import '../security/security_policy.dart';
import 'product_install_layout.dart';

/// Desktop has no Android socket exposure policy. It preserves the compiled
/// profile unchanged until desktop runtime policy is introduced.
class DesktopSecurityPolicy implements SecurityPolicy {
  const DesktopSecurityPolicy({this.processPaths = const []});

  factory DesktopSecurityPolicy.currentInstall() {
    final layout = DesktopRuntimeLayout.current();
    return DesktopSecurityPolicy(
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
      updateParams;

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
    if (!config.tun.enable || processPaths.isEmpty) return config;
    final loopRules = [
      for (final processPath in processPaths)
        'PROCESS-PATH,$processPath,DIRECT',
    ];
    return config.copyWith(
      rule: [
        ...loopRules,
        for (final rule in config.rule)
          if (!loopRules.contains(rule)) rule,
      ],
    );
  }
}
