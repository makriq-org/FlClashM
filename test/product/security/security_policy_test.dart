import 'package:flclashm/enum/enum.dart';
import 'package:flclashm/models/models.dart';
import 'package:flclashm/product/compile/product_compile.dart';
import 'package:flclashm/product/security/product_security.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = AndroidSecurityPolicy();
  const metadata = CompiledProfileMetadata(
    externalController: '127.0.0.1:9090',
    tcpConcurrent: true,
    unifiedDelay: true,
    logLevel: 'info',
    keepAliveInterval: 30,
    groupDescriptions: {'Main': 'primary'},
  );

  group('AndroidSecurityPolicy', () {
    test('forces Android tun floor on direct patch config updates', () {
      final securedPatchConfig = policy.securePatchConfig(
        patchConfig: const ClashConfig(
          tun: Tun(
            enable: false,
            stack: TunStack.system,
          ),
        ),
        context: const SecurityPolicyContext(isAndroid: true),
      );

      expect(securedPatchConfig.tun.enable, isTrue);
      expect(securedPatchConfig.tun.stack, TunStack.system);
    });

    test('forces Android tun floor on live runtime updates', () {
      final securedUpdate = policy.secureRuntimeUpdate(
        updateParams: const UpdateParams(
          tun: Tun(
            enable: false,
            stack: TunStack.system,
          ),
          mixedPort: defaultMixedPort,
          allowLan: false,
          findProcessMode: FindProcessMode.off,
          mode: Mode.rule,
          logLevel: LogLevel.info,
          ipv6: true,
          tcpConcurrent: true,
          externalController: ExternalControllerStatus.close,
          unifiedDelay: true,
        ),
        context: const SecurityPolicyContext(isAndroid: true),
      );

      expect(securedUpdate.tun.enable, isTrue);
      expect(securedUpdate.tun.stack, TunStack.system);
    });

    test('forces Android tun floor as client policy', () {
      final securedProfile = policy.secureProfile(
        compiledProfile: const CompiledProfilePatch(
          patchConfig: ClashConfig(
            tun: Tun(
              enable: false,
              stack: TunStack.system,
            ),
          ),
          metadata: metadata,
        ),
        context: const SecurityPolicyContext(isAndroid: true),
      );

      expect(securedProfile.patchConfig.tun.enable, isTrue);
      expect(securedProfile.runtimeConstraints.enforceTun, isTrue);
      expect(securedProfile.metadata?.externalController,
          metadata.externalController);
    });

    test('keeps advisory compile result unchanged off Android', () {
      final securedProfile = policy.secureProfile(
        compiledProfile: const CompiledProfilePatch(
          patchConfig: ClashConfig(
            tun: Tun(
              enable: false,
              stack: TunStack.gvisor,
            ),
          ),
          metadata: metadata,
        ),
        context: const SecurityPolicyContext(isAndroid: false),
      );

      expect(securedProfile.patchConfig.tun.enable, isFalse);
      expect(securedProfile.patchConfig.tun.stack, TunStack.gvisor);
      expect(securedProfile.runtimeConstraints.enforceTun, isFalse);
      expect(securedProfile.metadata?.groupDescriptions,
          metadata.groupDescriptions);
    });
  });
}
