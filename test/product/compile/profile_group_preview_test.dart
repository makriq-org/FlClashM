import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/product/compile/product_compile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('profile group preview', () {
    test('builds visible proxy groups from raw profile config', () {
      final groups = buildProfileGroupPreview(
        const <String, dynamic>{
          'proxies': [
            {
              'name': 'DE HY2',
              'type': 'hysteria2',
              'server': 'hy2.example.com',
            },
            {
              'name': 'Russia',
              'type': 'socks5',
              'server': 'ru.example.com',
            },
          ],
          'proxy-groups': [
            {
              'name': 'Locations',
              'type': 'select',
              'proxies': ['Germany', 'DIRECT'],
              'url': 'https://cp.cloudflare.com/generate_204',
            },
            {
              'name': 'Germany',
              'type': 'fallback',
              'hidden': true,
              'proxies': ['DE HY2', 'Russia'],
            },
          ],
        },
      );

      expect(groups, hasLength(2));
      expect(groups[0].name, 'Locations');
      expect(groups[0].type, GroupType.Selector);
      expect(groups[0].hidden, isFalse);
      expect(groups[0].now, 'Germany');
      expect(groups[0].testUrl, 'https://cp.cloudflare.com/generate_204');
      expect(groups[0].all[0].name, 'Germany');
      expect(groups[0].all[0].type, GroupType.Fallback.value);
      expect(groups[0].all[1].name, 'DIRECT');

      expect(groups[1].name, 'Germany');
      expect(groups[1].type, GroupType.Fallback);
      expect(groups[1].hidden, isTrue);
      expect(groups[1].all[0].type, 'hysteria2');
      expect(groups[1].all[0].serverDescription, 'hy2.example.com');
    });
  });
}
