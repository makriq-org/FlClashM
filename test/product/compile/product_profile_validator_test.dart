import 'package:flclashm/product/compile/product_compile.dart';
import 'package:flclashm/product/runtime/product_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const validator = ProductProfileValidator();

  group('ProductProfileValidator', () {
    test('normalizes built-in proxy nodes into core-compatible local proxies',
        () {
      final normalized = validator.normalizeForValidation('''
proxies:
  - name: NaiveProxy Local
    type: naiveproxy
    proxy: https://user:pass@example.com
proxy-groups:
  - name: Main
    type: select
    proxies:
      - NaiveProxy Local
rules:
  - MATCH,Main
''');

      expect(normalized['proxies'][0]['type'], 'socks5');
      expect(normalized['proxies'][0]['server'], '127.0.0.1');
      expect(
        normalized['proxy-groups'][0]['proxies'],
        ['NaiveProxy Local'],
      );
      expect(normalized['rules'], ['MATCH,Main']);
      expect(normalized.containsKey('x-flclashm-runtime'), isFalse);
    });

    test('normalizes olcrtc nodes into core-compatible local proxies', () {
      final normalized = validator.normalizeForValidation('''
proxies:
  - name: OLC Local
    type: olcrtc
    auth:
      provider: jitsi
    room:
      id: https://meet.example.org/room
    crypto:
      key: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    net:
      transport: datachannel
      dns: 8.8.8.8:53
''');

      expect(normalized['proxies'][0]['type'], 'socks5');
      expect(normalized['proxies'][0]['server'], '127.0.0.1');
      expect(normalized['proxies'][0]['port'], inInclusiveRange(35900, 36155));
    });

    test('rejects legacy top-level naiveproxy runtime selection', () {
      expect(
        () => validator.normalizeForValidation('''
x-flclashm-runtime:
  engine: naiveproxy
  naiveproxy:
    proxy: https://user:pass@example.com
'''),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Legacy `x-flclashm-runtime.engine=naiveproxy`'),
          ),
        ),
      );
    });

    test('rejects unsupported built-in node types at validation time', () {
      expect(
        () => validator.normalizeForValidation('''
proxies:
  - name: ByeDPI Local
    type: byedpi
'''),
        throwsA(
          isA<UnsupportedBuiltInProxyException>().having(
            (error) => error.message,
            'message',
            contains('byedpi built-in node is not available'),
          ),
        ),
      );
    });
  });
}
