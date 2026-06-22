import 'package:flclashx/models/models.dart';
import 'package:flutter/foundation.dart';

import '../compile/runtime_plan.dart';

@immutable
class SecurityPolicyContext {
  const SecurityPolicyContext({
    required this.isAndroid,
  });

  final bool isAndroid;
}

@immutable
class RuntimeSecurityConstraints {
  const RuntimeSecurityConstraints({
    this.enforceTun = false,
  });

  final bool enforceTun;
}

@immutable
class SecuredProfilePatch {
  const SecuredProfilePatch({
    required this.patchConfig,
    required this.metadata,
    this.runtimeConstraints = const RuntimeSecurityConstraints(),
  });

  final ClashConfig patchConfig;
  final CompiledProfileMetadata? metadata;
  final RuntimeSecurityConstraints runtimeConstraints;
}

abstract interface class SecurityPolicy {
  const SecurityPolicy();

  ClashConfig securePatchConfig({
    required ClashConfig patchConfig,
    required SecurityPolicyContext context,
  });

  UpdateParams secureRuntimeUpdate({
    required UpdateParams updateParams,
    required SecurityPolicyContext context,
  });

  SecuredProfilePatch secureProfile({
    required CompiledProfilePatch compiledProfile,
    required SecurityPolicyContext context,
  });
}
