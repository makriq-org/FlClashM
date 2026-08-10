import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/product_compile.dart';
import 'package:flclashx/product/platform/desktop_security_policy.dart';
import 'package:flclashx/product/security/product_security.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = AndroidSecurityPolicy();
  const metadata = CompiledProfileMetadata(
    externalController: '0.0.0.0:9090',
    secret: '',
    tcpConcurrent: true,
    unifiedDelay: true,
    logLevel: 'info',
    keepAliveInterval: 30,
    groupDescriptions: {'Main': 'primary'},
  );

  group('AndroidSecurityPolicy', () {
    test('new installations keep VPN enabled by default', () {
      expect(defaultVpnProps.enable, isTrue);
    });

    test('keeps the user VPN choice on direct Android patch updates', () {
      final securedPatchConfig = policy.securePatchConfig(
        patchConfig: const ClashConfig(
          allowLan: true,
          externalController: ExternalControllerStatus.open,
          tun: Tun(enable: false, stack: TunStack.system),
        ),
        context: const SecurityPolicyContext(isAndroid: true),
      );

      expect(securedPatchConfig.tun.enable, isFalse);
      expect(securedPatchConfig.tun.stack, TunStack.system);
      expect(securedPatchConfig.allowLan, isTrue);
      expect(
        securedPatchConfig.externalController,
        ExternalControllerStatus.open,
      );
    });

    test('keeps the user VPN choice on live Android runtime updates', () {
      final securedUpdate = policy.secureRuntimeUpdate(
        updateParams: const UpdateParams(
          tun: Tun(enable: false, stack: TunStack.system),
          mixedPort: defaultMixedPort,
          allowLan: true,
          findProcessMode: FindProcessMode.off,
          mode: Mode.rule,
          logLevel: LogLevel.info,
          ipv6: true,
          tcpConcurrent: true,
          externalController: ExternalControllerStatus.open,
          unifiedDelay: true,
        ),
        context: const SecurityPolicyContext(isAndroid: true),
      );

      expect(securedUpdate.tun.enable, isFalse);
      expect(securedUpdate.tun.stack, TunStack.system);
      expect(securedUpdate.allowLan, isTrue);
      expect(securedUpdate.externalController, ExternalControllerStatus.open);
    });

    test('keeps the user VPN choice while securing an Android profile', () {
      final securedProfile = policy.secureProfile(
        compiledProfile: const CompiledProfilePatch(
          patchConfig: ClashConfig(
            allowLan: true,
            externalController: ExternalControllerStatus.open,
            tun: Tun(enable: false, stack: TunStack.system),
          ),
          metadata: metadata,
        ),
        context: const SecurityPolicyContext(isAndroid: true),
      );

      expect(securedProfile.patchConfig.tun.enable, isFalse);
      expect(securedProfile.runtimeConstraints.enforceTun, isFalse);
      expect(securedProfile.metadata, same(metadata));
      expect(securedProfile.patchConfig.allowLan, isTrue);
      expect(
        securedProfile.patchConfig.externalController,
        ExternalControllerStatus.open,
      );
    });

    test('androidsecure disables mixed port without enabling VPN', () {
      final securedProfile = policy.secureProfile(
        compiledProfile: const CompiledProfilePatch(
          patchConfig: ClashConfig(
            mixedPort: 7890,
            tun: Tun(enable: false),
          ),
          metadata: metadata,
        ),
        context: const SecurityPolicyContext(
          isAndroid: true,
          androidSecure: true,
        ),
      );
      final securedUpdate = policy.secureRuntimeUpdate(
        updateParams: const UpdateParams(
          tun: Tun(enable: false),
          mixedPort: 7890,
          allowLan: true,
          findProcessMode: FindProcessMode.off,
          mode: Mode.rule,
          logLevel: LogLevel.info,
          ipv6: true,
          tcpConcurrent: true,
          externalController: ExternalControllerStatus.open,
          unifiedDelay: true,
        ),
        context: const SecurityPolicyContext(
          isAndroid: true,
          androidSecure: true,
        ),
      );

      expect(securedProfile.patchConfig.mixedPort, 0);
      expect(securedProfile.patchConfig.tun.enable, isFalse);
      expect(securedUpdate.mixedPort, 0);
      expect(securedUpdate.tun.enable, isFalse);
    });

    test('keeps advisory compile result unchanged off Android', () {
      final securedProfile = policy.secureProfile(
        compiledProfile: const CompiledProfilePatch(
          patchConfig: ClashConfig(
            tun: Tun(enable: false, stack: TunStack.gvisor),
          ),
          metadata: metadata,
        ),
        context: const SecurityPolicyContext(isAndroid: false),
      );

      expect(securedProfile.patchConfig.tun.enable, isFalse);
      expect(securedProfile.patchConfig.tun.stack, TunStack.gvisor);
      expect(securedProfile.runtimeConstraints.enforceTun, isFalse);
      expect(
        securedProfile.metadata?.groupDescriptions,
        metadata.groupDescriptions,
      );
    });
  });

  group('DesktopSecurityPolicy', () {
    const desktopPolicy = DesktopSecurityPolicy(
      processPaths: ['/opt/flclashm/mihomo', '/opt/flclashm/byedpi'],
    );

    test('prepends exact direct process rules only when TUN is enabled', () {
      final secured = desktopPolicy.secureProfile(
        compiledProfile: const CompiledProfilePatch(
          patchConfig: ClashConfig(
            tun: Tun(enable: true),
            rule: ['DOMAIN,example.com,Proxy'],
          ),
          metadata: null,
        ),
        context: const SecurityPolicyContext(isAndroid: false),
      );

      expect(secured.patchConfig.rule, [
        'PROCESS-PATH,/opt/flclashm/mihomo,DIRECT',
        'PROCESS-PATH,/opt/flclashm/byedpi,DIRECT',
        'DOMAIN,example.com,Proxy',
      ]);
    });

    test('does not mutate a non-TUN effective config', () {
      const source = ClashConfig(
        tun: Tun(enable: false),
        rule: ['MATCH,Proxy'],
      );
      final secured = desktopPolicy.securePatchConfig(
        patchConfig: source,
        context: const SecurityPolicyContext(isAndroid: false),
      );
      expect(secured, same(source));
    });
  });
}
