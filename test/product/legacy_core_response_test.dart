import 'dart:convert';

import 'package:flclashx/core/lib.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rule, global and direct modes project the right group visibility', () {
    final container = ProviderContainer(
      overrides: [
        groupsProvider.overrideWithBuild(
          (_, _) => const [
            Group(name: 'GLOBAL', type: GroupType.Selector, hidden: true),
            Group(name: 'configured', type: GroupType.Selector, hidden: false),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      currentGroupsStateProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    expect(
      container.read(currentGroupsStateProvider).value.map((g) => g.name),
      ['configured'],
    );
    container.read(patchClashConfigProvider.notifier).value =
        const PatchClashConfig(mode: Mode.global);
    expect(
      container.read(currentGroupsStateProvider).value.map((g) => g.name),
      ['GLOBAL', 'configured'],
    );
    container.read(patchClashConfigProvider.notifier).value =
        const PatchClashConfig(mode: Mode.direct);
    expect(container.read(currentGroupsStateProvider).value, isEmpty);
  });

  test('delay UI sends the legacy JSON payload and reads its result', () async {
    final core = CoreLib(
      legacyInvoke: (method, data) async {
        expect(method, 'asyncTestDelay');
        expect(data, isA<String>());
        final params = jsonDecode(data! as String) as Map;
        expect(params['proxy-name'], 'node-a');
        expect(params['test-url'], 'https://example.com/check');
        expect(params['timeout'], greaterThan(0));
        return jsonEncode({
          'name': params['proxy-name'],
          'url': params['test-url'],
          'value': 42,
        });
      },
    );
    final delay = await core.asyncTestDelay(
      'https://example.com/check',
      'node-a',
    );
    expect(delay?.value, 42);
    expect(delay?.name, 'node-a');
    expect(delay?.url, 'https://example.com/check');
  });

  test('proxy UI uses the ordered diagnostic envelope', () async {
    final core = CoreLib(
      legacyInvoke: (method, data) async {
        expect(method, 'getProxiesData');
        return {
          'all': ['second', 'first', 'GLOBAL'],
          'proxies': {
            'GLOBAL': {
              'type': 'Selector',
              'hidden': true,
              'all': ['DIRECT'],
            },
            'first': {
              'type': 'Selector',
              'hidden': false,
              'all': ['DIRECT'],
            },
            'second': {
              'type': 'Selector',
              'hidden': false,
              'all': ['DIRECT'],
            },
          },
        };
      },
    );
    final proxies = await core.getProxies();
    expect(proxies.all, ['second', 'first', 'GLOBAL']);
    expect(proxies.proxies['GLOBAL']['hidden'], true);
  });

  test('absent legacy provider is nullable and malformed JSON still fails', () {
    expect(decodeLegacyResult(''), isNull);
    expect(decodeLegacyResult('null'), isNull);
    expect(() => decodeLegacyResult('{'), throwsFormatException);
  });

  test('channel maps retain types for generated route and proxy models', () {
    final route = RouteSnapshot.fromJson(
      normalizeLegacyJson(<dynamic, dynamic>{
        'picks': <dynamic, dynamic>{'group': 'DIRECT'},
      }),
    );
    expect(route.picks, {'group': 'DIRECT'});
    final proxies = ProxiesData.fromJson(
      normalizeLegacyJson(<dynamic, dynamic>{
        'all': ['group'],
        'proxies': <dynamic, dynamic>{
          'group': <dynamic, dynamic>{
            'type': 'Selector',
            'all': ['DIRECT'],
          },
        },
      }),
    );
    expect(proxies.proxies['group'], isA<Map<String, dynamic>>());
  });

  test('flat engine proxies become a typed upstream proxy envelope', () {
    final response = legacyProxyEnvelope(<dynamic, dynamic>{
      'group': <String, dynamic>{
        'type': 'Selector',
        'all': ['DIRECT'],
      },
    });
    final proxies = ProxiesData.fromJson(response);
    expect(proxies.all, ['group']);
    expect(proxies.proxies['group']['all'], ['DIRECT']);
  });

  test('a group named proxies is not mistaken for a response envelope', () {
    final response = legacyProxyEnvelope({
      'proxies': {
        'type': 'Selector',
        'all': ['DIRECT'],
      },
      'all': {
        'type': 'Selector',
        'all': ['DIRECT'],
      },
    });
    expect(ProxiesData.fromJson(response).all, ['proxies', 'all']);
  });
}
