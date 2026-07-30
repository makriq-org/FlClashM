import 'package:flclashx/models/models.dart';

import '../compile/runtime_plan.dart';
import 'security_policy.dart';

class AndroidSecurityPolicy implements SecurityPolicy {
  const AndroidSecurityPolicy();

  @override
  ClashConfig securePatchConfig({
    required ClashConfig patchConfig,
    required SecurityPolicyContext context,
  }) =>
      context.isAndroid && context.androidSecure
          ? patchConfig.copyWith(mixedPort: 0)
          : patchConfig;

  @override
  UpdateParams secureRuntimeUpdate({
    required UpdateParams updateParams,
    required SecurityPolicyContext context,
  }) =>
      context.isAndroid && context.androidSecure
          ? updateParams.copyWith(mixedPort: 0)
          : updateParams;

  @override
  SecuredProfilePatch secureProfile({
    required CompiledProfilePatch compiledProfile,
    required SecurityPolicyContext context,
  }) =>
      SecuredProfilePatch(
        patchConfig: context.isAndroid && context.androidSecure
            ? compiledProfile.patchConfig.copyWith(mixedPort: 0)
            : compiledProfile.patchConfig,
        metadata: compiledProfile.metadata,
      );
}

const androidSecurityPolicy = AndroidSecurityPolicy();
