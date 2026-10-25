import 'package:flclashx/core/lib.dart';
import 'package:flclashx/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
