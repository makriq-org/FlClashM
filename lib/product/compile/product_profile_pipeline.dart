import 'package:flclashx/models/models.dart';

import '../platform/product_platform_composition.dart';
import '../security/product_security.dart';
import 'profile_compiler.dart';
import 'raw_profile.dart';
import 'runtime_plan.dart';

class ProductProfilePipeline {
  const ProductProfilePipeline({
    this.profileCompiler = const ProfileCompiler(),
    SecurityPolicy? securityPolicy,
  }) : _securityPolicy = securityPolicy;

  final ProfileCompiler profileCompiler;
  final SecurityPolicy? _securityPolicy;

  SecurityPolicy get securityPolicy =>
      _securityPolicy ?? productPlatformComposition.securityPolicy;

  ClashConfig securePatchConfig({
    required ClashConfig patchConfig,
    required SecurityPolicyContext context,
  }) =>
      securityPolicy.securePatchConfig(
        patchConfig: patchConfig,
        context: context,
      );

  UpdateParams secureRuntimeUpdate({
    required UpdateParams updateParams,
    required SecurityPolicyContext context,
  }) =>
      securityPolicy.secureRuntimeUpdate(
        updateParams: updateParams,
        context: context,
      );

  CompiledProfilePatch compileProfilePatch({
    required RawProfile? rawProfile,
    required ProfilePatchContext context,
  }) =>
      profileCompiler.compileProfilePatch(
        rawProfile: rawProfile,
        context: context,
      );

  SecuredProfilePatch secureProfilePatch({
    required CompiledProfilePatch compiledProfile,
    required SecurityPolicyContext context,
  }) =>
      securityPolicy.secureProfile(
        compiledProfile: compiledProfile,
        context: context,
      );

  Future<RuntimePlan> buildRuntimePlan({
    required RawProfile? rawProfile,
    required RuntimePlanBuildContext context,
    required SecuredProfilePatch securedProfile,
    required ClashConfig runtimePatchConfig,
    required Map<String, String> selectedMap,
    required String testUrl,
    required ProviderAssetPathResolver providerAssetPathResolver,
  }) =>
      profileCompiler.buildRuntimePlan(
        rawProfile: rawProfile,
        context: context,
        securedProfile: securedProfile,
        runtimePatchConfig: runtimePatchConfig,
        selectedMap: selectedMap,
        testUrl: testUrl,
        providerAssetPathResolver: providerAssetPathResolver,
      );
}
