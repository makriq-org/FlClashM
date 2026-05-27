import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/product_compile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const compiler = ProfileCompiler();

  group('ProfileCompiler.resolvePatchConfig', () {
    test('syncs provider network settings and keeps fallback on invalid values',
        () {
      const rawProfileConfig = {
        'ipv6': false,
        'allow-lan': true,
        'mixed-port': 9091,
        'find-process-mode': 'invalid',
        'tun': {
          'stack': 'system',
        },
        'tcp-concurrent': false,
        'unified-delay': false,
        'log-level': 'warning',
        'keep-alive-interval': 45,
        'proxy-groups': [
          {
            'name': 'Auto',
            'description': 'provider description',
          },
        ],
      };

      const profile = Profile(
        id: 'profile-1',
        autoUpdateDuration: Duration.zero,
      );
      final rawProfile = RawProfile.fromConfig(
        profile: profile,
        config: Map<String, dynamic>.from(rawProfileConfig),
      );

      const patchConfig = ClashConfig(
        mixedPort: 7890,
        ipv6: true,
        allowLan: false,
        findProcessMode: FindProcessMode.strict,
        tun: Tun(
          enable: false,
          stack: TunStack.mixed,
        ),
      );

      final resolvedPatch = compiler.resolvePatchConfig(
        rawProfile: rawProfile,
        context: const ProfileCompileContext(
          patchConfig: patchConfig,
          overrideNetworkSettings: false,
          overrideDns: false,
          routeMode: RouteMode.config,
          isAndroid: true,
          hasCurrentScript: false,
        ),
      );

      expect(resolvedPatch.patchConfig.ipv6, isFalse);
      expect(resolvedPatch.patchConfig.allowLan, isTrue);
      expect(resolvedPatch.patchConfig.mixedPort, 9091);
      expect(
        resolvedPatch.patchConfig.findProcessMode,
        FindProcessMode.strict,
      );
      expect(resolvedPatch.patchConfig.tun.stack, TunStack.system);
      expect(resolvedPatch.patchConfig.tun.enable, isTrue);
      expect(
        resolvedPatch.metadata?.groupDescriptions,
        {'Auto': 'provider description'},
      );
      expect(resolvedPatch.metadata?.logLevel, 'warning');
    });

    test(
      'keeps UI overrides for network/runtime hints but preserves provider external-controller',
      () {
        const profile = Profile(
          id: 'profile-override',
          autoUpdateDuration: Duration.zero,
        );
        final rawProfile = RawProfile.fromConfig(
          profile: profile,
          config: const <String, dynamic>{
            'external-controller': '127.0.0.1:9091',
            'ipv6': false,
            'allow-lan': true,
            'mixed-port': 9091,
            'find-process-mode': 'off',
            'tun': {
              'stack': 'system',
            },
            'tcp-concurrent': false,
            'unified-delay': false,
            'log-level': 'warning',
            'keep-alive-interval': 45,
          },
        );

        const patchConfig = ClashConfig(
          mixedPort: 7890,
          ipv6: true,
          allowLan: false,
          findProcessMode: FindProcessMode.strict,
          logLevel: LogLevel.error,
          keepAliveInterval: 30,
          unifiedDelay: true,
          tcpConcurrent: true,
          tun: Tun(
            enable: false,
            stack: TunStack.mixed,
          ),
          externalController: ExternalControllerStatus.open,
        );

        final resolvedPatch = compiler.resolvePatchConfig(
          rawProfile: rawProfile,
          context: const ProfileCompileContext(
            patchConfig: patchConfig,
            overrideNetworkSettings: true,
            overrideDns: false,
            routeMode: RouteMode.config,
            isAndroid: false,
            hasCurrentScript: false,
          ),
        );

        expect(resolvedPatch.patchConfig.ipv6, isTrue);
        expect(resolvedPatch.patchConfig.allowLan, isFalse);
        expect(resolvedPatch.patchConfig.mixedPort, 7890);
        expect(
          resolvedPatch.patchConfig.findProcessMode,
          FindProcessMode.strict,
        );
        expect(resolvedPatch.patchConfig.tun.stack, TunStack.mixed);
        expect(resolvedPatch.metadata?.externalController, '127.0.0.1:9091');
        expect(resolvedPatch.metadata?.tcpConcurrent, isTrue);
        expect(resolvedPatch.metadata?.unifiedDelay, isTrue);
        expect(resolvedPatch.metadata?.logLevel, 'error');
        expect(resolvedPatch.metadata?.keepAliveInterval, 30);
      },
    );
  });

  group('ProfileCompiler.buildRuntimePlan', () {
    test('rewrites providers and merges dns, hosts and override rules',
        () async {
      const profile = Profile(
        id: 'profile-2',
        autoUpdateDuration: Duration.zero,
        overrideData: OverrideData(
          enable: true,
          rule: OverrideRule(
            addedRules: [
              Rule(
                id: 'rule-1',
                value: 'DOMAIN,example.com,Proxy',
              ),
            ],
          ),
        ),
      );

      final rawProfile = RawProfile.fromConfig(
        profile: profile,
        config: const <String, dynamic>{
          'external-controller': '127.0.0.1:9091',
          'dns': {
            'enable': false,
          },
          'rules': ['MATCH,DIRECT'],
          'proxy-providers': {
            'remote': {
              'type': 'http',
              'url': 'https://example.com/proxies.yaml',
            },
          },
          'rule-providers': {
            'ruleset': {
              'type': 'http',
              'url': 'https://example.com/rules.yaml',
            },
          },
          'sniffer': {
            'sniff': {
              'tls': {
                'ports': [443, 8443],
              },
            },
          },
          'proxy-groups': [
            {
              'name': 'Main',
              'description': 'primary group',
            },
          ],
        },
      );

      const patchConfig = ClashConfig(
        dns: Dns(
          nameserver: ['1.1.1.1'],
          nameserverPolicy: {
            'geosite:private': 'system://,https://dns.example/dns-query',
          },
        ),
        hosts: {
          'foo.test': '1.1.1.1, 2.2.2.2',
        },
      );

      final runtimePlan = await compiler.buildRuntimePlan(
        rawProfile: rawProfile,
        context: const ProfileCompileContext(
          patchConfig: patchConfig,
          overrideNetworkSettings: false,
          overrideDns: false,
          routeMode: RouteMode.config,
          isAndroid: false,
          hasCurrentScript: false,
        ),
        selectedMap: const {'Main': 'Proxy'},
        testUrl: 'https://cp.cloudflare.com/generate_204',
        providerAssetPathResolver: (profileId, type, url) async =>
            '/tmp/$profileId/$type/${Uri.parse(url).pathSegments.last}',
      );

      expect(
        runtimePlan.config['proxy-providers']['remote']['path'],
        '/tmp/profile-2/proxies/proxies.yaml',
      );
      expect(
        runtimePlan.config['rule-providers']['ruleset']['path'],
        '/tmp/profile-2/rules/rules.yaml',
      );
      expect(runtimePlan.config['external-controller'], '127.0.0.1:9091');
      expect(
        runtimePlan.config['dns']['nameserver'],
        ['1.1.1.1', 'system://'],
      );
      expect(
        runtimePlan.config['dns']['nameserver-policy']['geosite:private'],
        ['system://', 'https://dns.example/dns-query'],
      );
      expect(runtimePlan.config['hosts']['foo.test'], ['1.1.1.1', '2.2.2.2']);
      expect(
        runtimePlan.config['sniffer']['sniff']['tls']['ports'],
        ['443', '8443'],
      );
      expect(
        runtimePlan.config['rule'],
        ['DOMAIN,example.com,Proxy', 'MATCH,DIRECT'],
      );
      expect(runtimePlan.selectedMap, {'Main': 'Proxy'});
    });

    test('skips override rules when a script already compiled the profile',
        () async {
      const profile = Profile(
        id: 'profile-3',
        autoUpdateDuration: Duration.zero,
        overrideData: OverrideData(
          enable: true,
          rule: OverrideRule(
            addedRules: [
              Rule(
                id: 'rule-2',
                value: 'DOMAIN,example.com,Proxy',
              ),
            ],
          ),
        ),
      );

      final rawProfile = RawProfile.fromConfig(
        profile: profile,
        config: const <String, dynamic>{
          'rules': ['MATCH,DIRECT'],
        },
      );

      final runtimePlan = await compiler.buildRuntimePlan(
        rawProfile: rawProfile,
        context: const ProfileCompileContext(
          patchConfig: ClashConfig(),
          overrideNetworkSettings: false,
          overrideDns: false,
          routeMode: RouteMode.config,
          isAndroid: false,
          hasCurrentScript: true,
        ),
        selectedMap: const {},
        testUrl: 'https://cp.cloudflare.com/generate_204',
        providerAssetPathResolver: (profileId, type, url) async =>
            '/tmp/$profileId/$type/$url',
      );

      expect(runtimePlan.config['rule'], ['MATCH,DIRECT']);
    });
  });
}
