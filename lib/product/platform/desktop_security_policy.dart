import 'package:flclashx/models/models.dart';

import '../compile/runtime_plan.dart';
import '../security/security_policy.dart';

/// Desktop has no Android socket exposure policy. It preserves the compiled
/// profile unchanged until desktop runtime policy is introduced.
class DesktopSecurityPolicy implements SecurityPolicy {
  const DesktopSecurityPolicy();

  @override
  ClashConfig securePatchConfig({
    required ClashConfig patchConfig,
    required SecurityPolicyContext context,
  }) =>
      patchConfig;

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
        patchConfig: compiledProfile.patchConfig,
        metadata: compiledProfile.metadata,
      );
}
