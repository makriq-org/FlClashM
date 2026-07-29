import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/product_compile.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flclashx/product/runtime/runtime_types.dart';
import 'package:flclashx/product/security/product_security.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

void main() {
  const compiler = ProfileCompiler();

  group('ProfileCompiler.compileProfilePatch', () {
    test('syncs provider hints and keeps fallback on invalid values', () {
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

      final compiledProfile = compiler.compileProfilePatch(
        rawProfile: rawProfile,
        context: const ProfilePatchContext(
          patchConfig: patchConfig,
          overrideNetworkSettings: false,
        ),
      );

      expect(compiledProfile.patchConfig.ipv6, isFalse);
      expect(compiledProfile.patchConfig.allowLan, isTrue);
      expect(compiledProfile.patchConfig.mixedPort, 9091);
      expect(
        compiledProfile.patchConfig.findProcessMode,
        FindProcessMode.strict,
      );
      expect(compiledProfile.patchConfig.tun.stack, TunStack.system);
      expect(compiledProfile.patchConfig.tun.enable, isFalse);
      expect(
        compiledProfile.metadata?.groupDescriptions,
        {'Auto': 'provider description'},
      );
      expect(compiledProfile.metadata?.logLevel, 'warning');
    });

    test(
      'keeps UI overrides for advisory network/runtime hints including external-controller',
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

        final compiledProfile = compiler.compileProfilePatch(
          rawProfile: rawProfile,
          context: const ProfilePatchContext(
            patchConfig: patchConfig,
            overrideNetworkSettings: true,
          ),
        );

        expect(compiledProfile.patchConfig.ipv6, isTrue);
        expect(compiledProfile.patchConfig.allowLan, isFalse);
        expect(compiledProfile.patchConfig.mixedPort, 7890);
        expect(
          compiledProfile.patchConfig.findProcessMode,
          FindProcessMode.strict,
        );
        expect(compiledProfile.patchConfig.tun.stack, TunStack.mixed);
        expect(
          compiledProfile.metadata?.externalController,
          ExternalControllerStatus.open.value,
        );
        expect(compiledProfile.metadata?.tcpConcurrent, isTrue);
        expect(compiledProfile.metadata?.unifiedDelay, isTrue);
        expect(compiledProfile.metadata?.logLevel, 'error');
        expect(compiledProfile.metadata?.keepAliveInterval, 30);
      },
    );
  });

  group('ProfileCompiler.buildRuntimePlan', () {
    test('writes sanitized compiled network settings into runtime config',
        () async {
      const profile = Profile(
        id: 'profile-sanitized',
        autoUpdateDuration: Duration.zero,
      );

      final rawProfile = RawProfile.fromConfig(
        profile: profile,
        config: const <String, dynamic>{
          'ipv6': 'bad',
          'allow-lan': 'bad',
          'mixed-port': 'bad',
          'find-process-mode': 'bad',
          'tun': {
            'stack': 'bad',
          },
        },
      );

      const patchConfig = ClashConfig(
        mixedPort: 7890,
        ipv6: true,
        allowLan: false,
        findProcessMode: FindProcessMode.strict,
        tun: Tun(
          enable: false,
          stack: TunStack.system,
        ),
      );

      final compiledProfile = compiler.compileProfilePatch(
        rawProfile: rawProfile,
        context: const ProfilePatchContext(
          patchConfig: patchConfig,
          overrideNetworkSettings: false,
        ),
      );

      final runtimePlan = await compiler.buildRuntimePlan(
        rawProfile: rawProfile,
        context: const RuntimePlanBuildContext(
          isAndroid: false,
          overrideNetworkSettings: false,
          overrideDns: false,
          routeMode: RouteMode.config,
          hasCurrentScript: false,
          profilesPath: '',
          homeDirPath: '/app-home',
          readInstalledPackageNames: _readNoInstalledPackages,
        ),
        securedProfile: SecuredProfilePatch(
          patchConfig: compiledProfile.patchConfig,
          metadata: compiledProfile.metadata,
        ),
        runtimePatchConfig: compiledProfile.patchConfig,
        selectedMap: const {},
        testUrl: 'https://cp.cloudflare.com/generate_204',
        providerAssetPathResolver: (profileId, type, url) async =>
            '/tmp/$profileId/$type/$url',
      );

      expect(runtimePlan.config['ipv6'], isTrue);
      expect(runtimePlan.config['allow-lan'], isFalse);
      expect(runtimePlan.config['mixed-port'], 7890);
      expect(runtimePlan.config['find-process-mode'], 'strict');
      expect(runtimePlan.config['tun']['stack'], 'system');
      expect(runtimePlan.config['external-ui'], '/app-home/zashboard');
    });

    test('defers Android proxy group health checks during setup', () async {
      const profile = Profile(
        id: 'profile-android-health-checks',
        autoUpdateDuration: Duration.zero,
      );
      final rawProfile = RawProfile.fromConfig(
        profile: profile,
        config: const <String, dynamic>{
          'proxy-groups': [
            {
              'name': 'Fallback',
              'type': 'fallback',
              'lazy': false,
            },
            {
              'name': 'UrlTest',
              'type': 'url-test',
              'lazy': false,
            },
            {
              'name': 'Balance',
              'type': 'load-balance',
              'lazy': false,
            },
            {
              'name': 'Manual',
              'type': 'select',
              'lazy': false,
            },
          ],
        },
      );
      final compiledProfile = compiler.compileProfilePatch(
        rawProfile: rawProfile,
        context: const ProfilePatchContext(
          patchConfig: ClashConfig(tun: Tun(enable: false)),
          overrideNetworkSettings: false,
        ),
      );

      final runtimePlan = await compiler.buildRuntimePlan(
        rawProfile: rawProfile,
        context: const RuntimePlanBuildContext(
          isAndroid: true,
          overrideNetworkSettings: false,
          overrideDns: false,
          routeMode: RouteMode.config,
          hasCurrentScript: false,
          profilesPath: '',
          readInstalledPackageNames: _readNoInstalledPackages,
        ),
        securedProfile: SecuredProfilePatch(
          patchConfig: compiledProfile.patchConfig,
          metadata: compiledProfile.metadata,
        ),
        runtimePatchConfig: compiledProfile.patchConfig,
        selectedMap: const {},
        testUrl: 'https://cp.cloudflare.com/generate_204',
        providerAssetPathResolver: (profileId, type, url) async =>
            '/tmp/$profileId/$type/$url',
      );

      final groups = runtimePlan.config['proxy-groups'] as List<dynamic>;
      expect(groups[0]['lazy'], isTrue);
      expect(groups[1]['lazy'], isTrue);
      expect(groups[2]['lazy'], isTrue);
      expect(groups[3]['lazy'], isFalse);
    });

    test('propagates profile split tunneling into runtime plan', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('profile-compiler-split-');
      final profilesDir = Directory(path.join(tempDir.path, 'profiles'))
        ..createSync(recursive: true);
      File(path.join(profilesDir.path, 'lists', 'include.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('com.termux\n*.mozilla.*\n');

      const profile = Profile(
        id: 'profile-split',
        autoUpdateDuration: Duration.zero,
      );
      final rawProfile = RawProfile.fromConfig(
        profile: profile,
        config: const <String, dynamic>{
          'tun': {
            'include-package-file': 'lists/include.txt',
          },
        },
      );
      final compiledProfile = compiler.compileProfilePatch(
        rawProfile: rawProfile,
        context: const ProfilePatchContext(
          patchConfig: ClashConfig(
            tun: Tun(
              enable: true,
              stack: TunStack.system,
            ),
          ),
          overrideNetworkSettings: false,
        ),
      );

      final runtimePlan = await compiler.buildRuntimePlan(
        rawProfile: rawProfile,
        context: RuntimePlanBuildContext(
          isAndroid: true,
          overrideNetworkSettings: false,
          overrideDns: false,
          routeMode: RouteMode.config,
          hasCurrentScript: false,
          profilesPath: profilesDir.path,
          readInstalledPackageNames: () async => const [
            'com.termux',
            'org.mozilla.firefox',
          ],
        ),
        securedProfile: SecuredProfilePatch(
          patchConfig: compiledProfile.patchConfig,
          metadata: compiledProfile.metadata,
        ),
        runtimePatchConfig: compiledProfile.patchConfig,
        selectedMap: const {},
        testUrl: 'https://cp.cloudflare.com/generate_204',
        providerAssetPathResolver: (profileId, type, url) async =>
            '/tmp/$profileId/$type/$url',
      );

      expect(
        runtimePlan.config['tun']['include-package'],
        ['com.termux', 'org.mozilla.firefox'],
      );
      expect(
        runtimePlan.config['tun'].containsKey('include-package-file'),
        isFalse,
      );
      expect(
        runtimePlan.profileAccessControl,
        const AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: ['com.termux', 'org.mozilla.firefox'],
        ),
      );

      await tempDir.delete(recursive: true);
    });

    test('cold start preserves every Android split-tunneling source type',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('cold-split-');
      final profilesDir = Directory(path.join(tempDir.path, 'profiles'))
        ..createSync(recursive: true);
      File(path.join(profilesDir.path, 'lists', 'include.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('com.android.chrome\n');
      const networkUrl = 'https://example.com/include.txt';
      final refreshStarted = Completer<void>();
      File(
        path.join(
          profilesDir.path,
          'providers',
          'profile-split-disabled',
          'packages',
          networkUrl.toMd5(),
        ),
      )
        ..createSync(recursive: true)
        ..writeAsStringSync('com.network.app\n');
      const profile = Profile(
        id: 'profile-split-disabled',
        autoUpdateDuration: Duration.zero,
      );
      final rawProfile = RawProfile.fromConfig(
        profile: profile,
        config: const <String, dynamic>{
          'tun': {
            'include-package': [
              'com.termux',
              '*.mozilla.*',
              r're:^org\.telegram\..+$',
            ],
            'include-package-file': 'lists/include.txt',
            'include-package-url': networkUrl,
          },
        },
      );
      final compiledProfile = compiler.compileProfilePatch(
        rawProfile: rawProfile,
        context: const ProfilePatchContext(
          patchConfig: ClashConfig(
            tun: Tun(enable: false),
          ),
          overrideNetworkSettings: false,
        ),
      );

      final runtimePlan = await compiler.buildRuntimePlan(
        rawProfile: rawProfile,
        context: RuntimePlanBuildContext(
          isAndroid: true,
          overrideNetworkSettings: false,
          overrideDns: false,
          routeMode: RouteMode.config,
          hasCurrentScript: false,
          profilesPath: profilesDir.path,
          readInstalledPackageNames: () async => const [
            'com.termux',
            'org.mozilla.firefox',
            'org.telegram.messenger',
            'com.android.chrome',
            'com.network.app',
          ],
          readSplitTunnelingRemoteSource: (_) async {
            refreshStarted.complete();
            return 'com.network.app\n';
          },
        ),
        securedProfile: SecuredProfilePatch(
          patchConfig: compiledProfile.patchConfig,
          metadata: compiledProfile.metadata,
        ),
        runtimePatchConfig: compiledProfile.patchConfig,
        selectedMap: const {},
        testUrl: 'https://cp.cloudflare.com/generate_204',
        providerAssetPathResolver: (profileId, type, url) async =>
            '/tmp/$profileId/$type/$url',
      );

      expect(
        runtimePlan.profileAccessControl,
        const AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: [
            'com.termux',
            'org.mozilla.firefox',
            'org.telegram.messenger',
            'com.android.chrome',
            'com.network.app',
          ],
        ),
      );
      expect(
        runtimePlan.config['tun']['include-package'],
        [
          'com.termux',
          'org.mozilla.firefox',
          'org.telegram.messenger',
          'com.android.chrome',
          'com.network.app',
        ],
      );
      expect(runtimePlan.config['tun']['enable'], isFalse);
      expect(
        runtimePlan.config['tun'].keys,
        isNot(contains('include-package-file')),
      );
      expect(
        runtimePlan.config['tun'].keys,
        isNot(contains('include-package-url')),
      );
      await refreshStarted.future;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tempDir.delete(recursive: true);
    });

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
      final compiledProfile = compiler.compileProfilePatch(
        rawProfile: rawProfile,
        context: const ProfilePatchContext(
          patchConfig: patchConfig,
          overrideNetworkSettings: false,
        ),
      );

      final runtimePlan = await compiler.buildRuntimePlan(
        rawProfile: rawProfile,
        context: const RuntimePlanBuildContext(
          isAndroid: false,
          overrideNetworkSettings: false,
          overrideDns: false,
          routeMode: RouteMode.config,
          hasCurrentScript: false,
          profilesPath: '',
          readInstalledPackageNames: _readNoInstalledPackages,
        ),
        securedProfile: SecuredProfilePatch(
          patchConfig: compiledProfile.patchConfig,
          metadata: compiledProfile.metadata,
        ),
        runtimePatchConfig: patchConfig,
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
      final compiledProfile = compiler.compileProfilePatch(
        rawProfile: rawProfile,
        context: const ProfilePatchContext(
          patchConfig: ClashConfig(),
          overrideNetworkSettings: false,
        ),
      );

      final runtimePlan = await compiler.buildRuntimePlan(
        rawProfile: rawProfile,
        context: const RuntimePlanBuildContext(
          isAndroid: false,
          overrideNetworkSettings: false,
          overrideDns: false,
          routeMode: RouteMode.config,
          hasCurrentScript: true,
          profilesPath: '',
          readInstalledPackageNames: _readNoInstalledPackages,
        ),
        securedProfile: SecuredProfilePatch(
          patchConfig: compiledProfile.patchConfig,
          metadata: compiledProfile.metadata,
        ),
        runtimePatchConfig: const ClashConfig(),
        selectedMap: const {},
        testUrl: 'https://cp.cloudflare.com/generate_204',
        providerAssetPathResolver: (profileId, type, url) async =>
            '/tmp/$profileId/$type/$url',
      );

      expect(runtimePlan.config['rule'], ['MATCH,DIRECT']);
    });

    test('builds naiveproxy runtime artifacts and local SOCKS bridge',
        () async {
      const profile = Profile(
        id: 'profile-naiveproxy',
        autoUpdateDuration: Duration.zero,
      );

      final rawProfile = RawProfile.fromConfig(
        profile: profile,
        config: const <String, dynamic>{
          'dns': {
            'enable': true,
            'nameserver': ['1.1.1.1'],
          },
          'proxies': [
            {
              'name': 'NaiveProxy Local',
              'type': 'naiveproxy',
              'server': 'example.com',
              'port': 443,
              'username': 'user',
              'password': 'pass',
              'host-resolver-rules': 'MAP * ~NOTFOUND , EXCLUDE localhost',
            },
          ],
          'proxy-groups': [
            {
              'name': 'Main',
              'type': 'select',
              'proxies': ['NaiveProxy Local'],
            },
          ],
          'rules': ['MATCH,Main'],
        },
      );

      const patchConfig = ClashConfig(
        mixedPort: 7890,
        socksPort: 0,
        port: 8080,
        tun: Tun(
          enable: true,
          stack: TunStack.system,
        ),
      );

      final compiledProfile = compiler.compileProfilePatch(
        rawProfile: rawProfile,
        context: const ProfilePatchContext(
          patchConfig: patchConfig,
          overrideNetworkSettings: false,
        ),
      );

      final runtimePlan = await compiler.buildRuntimePlan(
        rawProfile: rawProfile,
        context: const RuntimePlanBuildContext(
          isAndroid: false,
          overrideNetworkSettings: false,
          overrideDns: false,
          routeMode: RouteMode.config,
          hasCurrentScript: false,
          profilesPath: '',
          readInstalledPackageNames: _readNoInstalledPackages,
        ),
        securedProfile: SecuredProfilePatch(
          patchConfig: compiledProfile.patchConfig,
          metadata: compiledProfile.metadata,
        ),
        runtimePatchConfig: compiledProfile.patchConfig,
        selectedMap: const {'Main': 'ignored'},
        testUrl: 'https://cp.cloudflare.com/generate_204',
        providerAssetPathResolver: (profileId, type, url) async =>
            '/tmp/$profileId/$type/$url',
      );

      expect(
        runtimePlan.runtime,
        const RuntimeSelection.mihomo(),
      );
      expect(runtimePlan.selectedMap, const {'Main': 'ignored'});
      expect(runtimePlan.builtInProxyNodes, hasLength(1));
      final builtInNode = runtimePlan.builtInProxyNodes.single;
      expect(builtInNode.type, BuiltInProxyType.naiveproxy);
      expect(builtInNode.listenPort, inInclusiveRange(35000, 35511));
      expect(runtimePlan.config['proxies'][0]['server'], '127.0.0.1');
      expect(runtimePlan.config['proxies'][0]['port'], builtInNode.listenPort);
      expect(
        runtimePlan.config['proxies'][0]['type'],
        'socks5',
      );
      expect(
        runtimePlan.config['proxy-groups'][0]['proxies'],
        ['NaiveProxy Local'],
      );

      final configJson = runtimePlan.files[
          'built-in-proxies/naiveproxy/${builtInNode.nodeId}/config.json'];
      expect(configJson, isNotNull);
      final runtimeConfig = Map<String, dynamic>.from(
        json.decode(configJson!) as Map,
      );
      expect(
        runtimeConfig['listen'],
        'socks://127.0.0.1:${builtInNode.listenPort}',
      );
      expect(runtimeConfig['proxy'], 'https://user:pass@example.com');
      expect(
        runtimeConfig['host-resolver-rules'],
        'MAP * ~NOTFOUND , EXCLUDE localhost',
      );
    });

    test(
        'keeps all built-in proxy runtime nodes from selector route with full core config',
        () async {
      const profile = Profile(
        id: 'profile-selected-built-in',
        autoUpdateDuration: Duration.zero,
      );

      final rawProfile = RawProfile.fromConfig(
        profile: profile,
        config: const <String, dynamic>{
          'proxies': [
            {
              'name': 'NaiveProxy Local',
              'type': 'naiveproxy',
              'server': 'example.com',
              'port': 443,
              'username': 'user',
              'password': 'pass',
            },
            {
              'name': 'ByeDPI Local',
              'type': 'byedpi',
              'mode': 'manual',
              'args': '--disorder 1',
            },
            {
              'name': 'OLC Local',
              'type': 'olcrtc',
              'activation': 'always',
              'auth': {'provider': 'jitsi'},
              'room': {'id': 'https://meet.example.org/room'},
              'crypto': {
                'key':
                    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
              },
              'net': {
                'transport': 'datachannel',
                'dns': '8.8.8.8:53',
              },
            },
          ],
          'proxy-groups': [
            {
              'name': 'Main',
              'type': 'select',
              'proxies': [
                'NaiveProxy Local',
                'ByeDPI Local',
                'OLC Local',
              ],
            },
          ],
          'rules': ['MATCH,Main'],
        },
      );

      final compiledProfile = compiler.compileProfilePatch(
        rawProfile: rawProfile,
        context: const ProfilePatchContext(
          patchConfig: ClashConfig(),
          overrideNetworkSettings: false,
        ),
      );

      final runtimePlan = await compiler.buildRuntimePlan(
        rawProfile: rawProfile,
        context: const RuntimePlanBuildContext(
          isAndroid: false,
          overrideNetworkSettings: false,
          overrideDns: false,
          routeMode: RouteMode.config,
          hasCurrentScript: false,
          profilesPath: '',
          readInstalledPackageNames: _readNoInstalledPackages,
        ),
        securedProfile: SecuredProfilePatch(
          patchConfig: compiledProfile.patchConfig,
          metadata: compiledProfile.metadata,
        ),
        runtimePatchConfig: compiledProfile.patchConfig,
        selectedMap: const {'Main': 'OLC Local'},
        testUrl: 'https://cp.cloudflare.com/generate_204',
        providerAssetPathResolver: (profileId, type, url) async =>
            '/tmp/$profileId/$type/$url',
      );

      expect(runtimePlan.config['proxies'], hasLength(3));
      expect(runtimePlan.builtInProxyNodes.map((node) => node.name), [
        'NaiveProxy Local',
        'ByeDPI Local',
        'OLC Local',
      ]);
      expect(
        runtimePlan.files.keys,
        containsAll([
          'built-in-proxies/naiveproxy/${runtimePlan.builtInProxyNodes[0].nodeId}/config.json',
          'built-in-proxies/byedpi/${runtimePlan.builtInProxyNodes[1].nodeId}/config.json',
          'built-in-proxies/olcrtc/${runtimePlan.builtInProxyNodes[2].nodeId}/config.yaml',
        ]),
      );
    });

    test('skips reserved runtime ports when allocating naiveproxy listeners',
        () async {
      const profile = Profile(
        id: 'profile-naiveproxy-port-collision',
        autoUpdateDuration: Duration.zero,
      );

      final rawProfile = RawProfile.fromConfig(
        profile: profile,
        config: const <String, dynamic>{
          'proxies': [
            {
              'name': 'NaiveProxy Local',
              'type': 'naiveproxy',
              'server': 'example.com',
              'port': 443,
              'username': 'user',
              'password': 'pass',
            },
          ],
        },
      );

      const patchConfig = ClashConfig(
        mixedPort: 35000,
        socksPort: 35001,
        redirPort: 35002,
      );

      final compiledProfile = compiler.compileProfilePatch(
        rawProfile: rawProfile,
        context: const ProfilePatchContext(
          patchConfig: patchConfig,
          overrideNetworkSettings: false,
        ),
      );

      final runtimePlan = await compiler.buildRuntimePlan(
        rawProfile: rawProfile,
        context: const RuntimePlanBuildContext(
          isAndroid: false,
          overrideNetworkSettings: false,
          overrideDns: false,
          routeMode: RouteMode.config,
          hasCurrentScript: false,
          profilesPath: '',
          readInstalledPackageNames: _readNoInstalledPackages,
        ),
        securedProfile: SecuredProfilePatch(
          patchConfig: compiledProfile.patchConfig,
          metadata: compiledProfile.metadata,
        ),
        runtimePatchConfig: compiledProfile.patchConfig,
        selectedMap: const {},
        testUrl: 'https://cp.cloudflare.com/generate_204',
        providerAssetPathResolver: (profileId, type, url) async =>
            '/tmp/$profileId/$type/$url',
      );

      final builtInNode = runtimePlan.builtInProxyNodes.single;
      expect(builtInNode.listenPort, isNot(anyOf(35000, 35001, 35002)));
      expect(builtInNode.listenPort, inInclusiveRange(35000, 35511));
    });

    test('builds byedpi runtime artifacts and local SOCKS bridge', () async {
      const profile = Profile(
        id: 'profile-byedpi',
        autoUpdateDuration: Duration.zero,
      );

      final rawProfile = RawProfile.fromConfig(
        profile: profile,
        config: const <String, dynamic>{
          'proxies': [
            {
              'name': 'ByeDPI Local',
              'type': 'byedpi',
              'mode': 'auto',
              'strategy-list': 'byebyeedpi',
              'strategy-test': {
                'urls': ['https://example.com/'],
                'sni': 'example.com',
              },
            },
          ],
        },
      );

      final compiledProfile = compiler.compileProfilePatch(
        rawProfile: rawProfile,
        context: const ProfilePatchContext(
          patchConfig: ClashConfig(),
          overrideNetworkSettings: false,
        ),
      );

      final runtimePlan = await compiler.buildRuntimePlan(
        rawProfile: rawProfile,
        context: const RuntimePlanBuildContext(
          isAndroid: false,
          overrideNetworkSettings: false,
          overrideDns: false,
          routeMode: RouteMode.config,
          hasCurrentScript: false,
          profilesPath: '',
          readInstalledPackageNames: _readNoInstalledPackages,
        ),
        securedProfile: SecuredProfilePatch(
          patchConfig: compiledProfile.patchConfig,
          metadata: compiledProfile.metadata,
        ),
        runtimePatchConfig: compiledProfile.patchConfig,
        selectedMap: const {},
        testUrl: 'https://cp.cloudflare.com/generate_204',
        providerAssetPathResolver: (profileId, type, url) async =>
            '/tmp/$profileId/$type/$url',
      );

      expect(runtimePlan.builtInProxyNodes, hasLength(1));
      final builtInNode = runtimePlan.builtInProxyNodes.single;
      expect(builtInNode.type, BuiltInProxyType.byedpi);
      expect(builtInNode.listenPort, inInclusiveRange(35600, 35855));
      expect(runtimePlan.config['proxies'][0]['type'], 'socks5');
      expect(runtimePlan.config['proxies'][0]['server'], '127.0.0.1');
      expect(runtimePlan.config['proxies'][0]['port'], builtInNode.listenPort);

      final configJson = runtimePlan
          .files['built-in-proxies/byedpi/${builtInNode.nodeId}/config.json'];
      expect(configJson, isNotNull);
      final runtimeConfig = Map<String, dynamic>.from(
        json.decode(configJson!) as Map,
      );
      expect(runtimeConfig['mode'], 'auto');
      expect(runtimeConfig['strategyList'], 'byebyeedpi');
      expect(runtimeConfig['listenPort'], builtInNode.listenPort);
      expect(runtimeConfig['strategyTest']['urls'], ['https://example.com/']);
    });

    test('builds olcrtc runtime artifacts and local SOCKS bridge', () async {
      const profile = Profile(
        id: 'profile-olcrtc',
        autoUpdateDuration: Duration.zero,
      );

      final rawProfile = RawProfile.fromConfig(
        profile: profile,
        config: const <String, dynamic>{
          'proxies': [
            {
              'name': 'OLC Local',
              'type': 'olcrtc',
              'activation': 'always',
              'auth': {'provider': 'jitsi'},
              'room': {'id': 'https://meet.example.org/room'},
              'crypto': {
                'key':
                    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
              },
              'net': {
                'transport': 'datachannel',
                'dns': '8.8.8.8:53',
              },
              'debug': true,
            },
          ],
        },
      );

      final compiledProfile = compiler.compileProfilePatch(
        rawProfile: rawProfile,
        context: const ProfilePatchContext(
          patchConfig: ClashConfig(),
          overrideNetworkSettings: false,
        ),
      );

      final runtimePlan = await compiler.buildRuntimePlan(
        rawProfile: rawProfile,
        context: const RuntimePlanBuildContext(
          isAndroid: false,
          overrideNetworkSettings: false,
          overrideDns: false,
          routeMode: RouteMode.config,
          hasCurrentScript: false,
          profilesPath: '',
          readInstalledPackageNames: _readNoInstalledPackages,
        ),
        securedProfile: SecuredProfilePatch(
          patchConfig: compiledProfile.patchConfig,
          metadata: compiledProfile.metadata,
        ),
        runtimePatchConfig: compiledProfile.patchConfig,
        selectedMap: const {},
        testUrl: 'https://cp.cloudflare.com/generate_204',
        providerAssetPathResolver: (profileId, type, url) async =>
            '/tmp/$profileId/$type/$url',
      );

      expect(runtimePlan.builtInProxyNodes, hasLength(1));
      final builtInNode = runtimePlan.builtInProxyNodes.single;
      expect(builtInNode.type, BuiltInProxyType.olcrtc);
      expect(builtInNode.listenPort, inInclusiveRange(35900, 36155));
      expect(runtimePlan.config['proxies'][0]['type'], 'socks5');
      expect(runtimePlan.config['proxies'][0]['server'], '127.0.0.1');
      expect(runtimePlan.config['proxies'][0]['port'], builtInNode.listenPort);

      final configYaml = runtimePlan
          .files['built-in-proxies/olcrtc/${builtInNode.nodeId}/config.yaml'];
      expect(configYaml, isNotNull);
      final runtimeConfig = loadYaml(configYaml!) as YamlMap;
      expect(runtimeConfig['mode'], 'cnc');
      expect(runtimeConfig['data'], 'data');
      expect(runtimeConfig['auth']['provider'], 'jitsi');
      expect(runtimeConfig['room']['id'], 'https://meet.example.org/room');
      expect(runtimeConfig['socks']['host'], '127.0.0.1');
      expect(runtimeConfig['socks']['port'], builtInNode.listenPort);
      expect(runtimeConfig['debug'], isTrue);
      expect(runtimeConfig, isNot(contains('profiles')));
    });

    test('rejects unsafe olcrtc local bind overrides before security', () {
      const profile = Profile(
        id: 'profile-olcrtc-bind',
        autoUpdateDuration: Duration.zero,
      );

      final rawProfile = RawProfile.fromConfig(
        profile: profile,
        config: const <String, dynamic>{
          'proxies': [
            {
              'name': 'OLC Local',
              'type': 'olcrtc',
              'activation': 'always',
              'socks': {'host': '0.0.0.0'},
            },
          ],
        },
      );
      expect(
        () => compiler.compileProfilePatch(
          rawProfile: rawProfile,
          context: const ProfilePatchContext(
            patchConfig: ClashConfig(),
            overrideNetworkSettings: false,
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('olcrtc.socks'),
          ),
        ),
      );
    });

    test('rejects non-client olcrtc modes and key files before security', () {
      const profile = Profile(
        id: 'profile-olcrtc-mode',
        autoUpdateDuration: Duration.zero,
      );

      void expectRejected(Map<String, dynamic> proxy) {
        proxy.putIfAbsent('activation', () => 'always');
        final rawProfile = RawProfile.fromConfig(
          profile: profile,
          config: {
            'proxies': [proxy],
          },
        );
        expect(
          () => compiler.compileProfilePatch(
            rawProfile: rawProfile,
            context: const ProfilePatchContext(
              patchConfig: ClashConfig(),
              overrideNetworkSettings: false,
            ),
          ),
          throwsA(isA<FormatException>()),
        );
      }

      expectRejected({
        'name': 'OLC Server',
        'type': 'olcrtc',
        'mode': 'srv',
      });
      expectRejected({
        'name': 'OLC Key File',
        'type': 'olcrtc',
        'crypto': {'key_file': './olcrtc.key'},
      });
      expectRejected({
        'name': 'OLC Nested Bind Host',
        'type': 'olcrtc',
        'profiles': [
          {
            'name': 'fallback',
            'socks': {'host': '0.0.0.0'},
          },
        ],
      });
      expectRejected({
        'name': 'OLC Deep Nested Bind Port',
        'type': 'olcrtc',
        'profiles': [
          {
            'name': 'fallback',
            'future': {
              'profiles': [
                {
                  'socks': {'port': 1080},
                },
              ],
            },
          },
        ],
      });
      expectRejected({
        'name': 'OLC Nested Key File',
        'type': 'olcrtc',
        'profiles': [
          {
            'name': 'fallback',
            'crypto': {'key_file': './olcrtc.key'},
          },
        ],
      });
      expectRejected({
        'name': 'OLC Invalid Profiles',
        'type': 'olcrtc',
        'profiles': {'name': 'not-a-list'},
      });
    });
  });
}

Future<List<String>> _readNoInstalledPackages() async => const [];
