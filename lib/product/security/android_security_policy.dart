import 'package:flclashm/models/models.dart';

import '../compile/runtime_plan.dart';
import 'security_policy.dart';

class AndroidSecurityPolicy implements SecurityPolicy {
  const AndroidSecurityPolicy();

  static const ignoredProviderHint = 'flclashm-androidsecure';

  @override
  ClashConfig securePatchConfig({
    required ClashConfig patchConfig,
    required SecurityPolicyContext context,
  }) =>
      context.isAndroid ? patchConfig.copyWith.tun(enable: true) : patchConfig;

  @override
  UpdateParams secureRuntimeUpdate({
    required UpdateParams updateParams,
    required SecurityPolicyContext context,
  }) =>
      context.isAndroid
          ? updateParams.copyWith(
              tun: updateParams.tun.copyWith(enable: true),
            )
          : updateParams;

  @override
  SecuredProfilePatch secureProfile({
    required CompiledProfilePatch compiledProfile,
    required SecurityPolicyContext context,
  }) {
    if (!context.isAndroid) {
      return SecuredProfilePatch(
        patchConfig: compiledProfile.patchConfig,
        metadata: compiledProfile.metadata,
      );
    }

    return SecuredProfilePatch(
      patchConfig: securePatchConfig(
        patchConfig: compiledProfile.patchConfig,
        context: context,
      ),
      metadata: compiledProfile.metadata,
      runtimeConstraints: const RuntimeSecurityConstraints(
        enforceTun: true,
      ),
    );
  }
}

const androidSecurityPolicy = AndroidSecurityPolicy();
