import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';

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
      context.isAndroid
          ? patchConfig
              .copyWith(
                externalController: _secureControllerStatus(
                  requested: patchConfig.externalController,
                  secret: context.controllerSecret,
                ),
              )
              .copyWith
              .tun(enable: true)
          : patchConfig;

  @override
  UpdateParams secureRuntimeUpdate({
    required UpdateParams updateParams,
    required SecurityPolicyContext context,
  }) =>
      context.isAndroid
          ? updateParams.copyWith(
              tun: updateParams.tun.copyWith(enable: true),
              externalController: _secureControllerStatus(
                requested: updateParams.externalController,
                secret: context.controllerSecret,
              ),
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

    final metadata = compiledProfile.metadata;
    final securedController = _secureControllerStatus(
      requested: context.explicitExternalController,
      secret: metadata?.secret ?? '',
    );
    return SecuredProfilePatch(
      patchConfig: compiledProfile.patchConfig
          .copyWith(
            allowLan: context.explicitAllowLan,
            externalController: securedController,
          )
          .copyWith
          .tun(
            enable: true,
          ),
      metadata: metadata == null
          ? null
          : CompiledProfileMetadata(
              externalController: securedController.value,
              secret: metadata.secret,
              tcpConcurrent: metadata.tcpConcurrent,
              unifiedDelay: metadata.unifiedDelay,
              logLevel: metadata.logLevel,
              keepAliveInterval: metadata.keepAliveInterval,
              groupDescriptions: metadata.groupDescriptions,
            ),
      runtimeConstraints: const RuntimeSecurityConstraints(
        enforceTun: true,
      ),
    );
  }

  ExternalControllerStatus _secureControllerStatus({
    required ExternalControllerStatus requested,
    required String secret,
  }) =>
      requested == ExternalControllerStatus.open && secret.trim().isNotEmpty
          ? ExternalControllerStatus.open
          : ExternalControllerStatus.close;
}

const androidSecurityPolicy = AndroidSecurityPolicy();
