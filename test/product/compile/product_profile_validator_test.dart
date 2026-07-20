import 'package:flclashx/product/compile/product_compile.dart';
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
    server: example.com
    port: 443
    username: user
    password: pass
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

    test('reports missing olcrtc DNS during profile validation', () {
      expect(
        () => validator.normalizeForValidation('''
proxies:
  - name: OLC Local
    type: olcrtc
    auth:
      provider: wbstream
    room:
      id: room-id
    crypto:
      key: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    net:
      transport: vp8channel
'''),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('requires `net.dns`'),
          ),
        ),
      );
    });

    test('materializes YAML merge keys before validation', () {
      final normalized = validator.normalizeForValidation('''
proxy-common: &proxy-common
  type: ss
  server: example.org
  port: 443
  cipher: aes-128-gcm
  password: secret
proxies:
  - <<: *proxy-common
    name: Merged Proxy
''');

      expect(normalized['proxies'][0]['type'], 'ss');
      expect(normalized['proxies'][0]['server'], 'example.org');
      expect(normalized['proxies'][0].containsKey('<<'), isFalse);
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

    test('normalizes byedpi nodes into core-compatible local proxies', () {
      final normalized = validator.normalizeForValidation('''
proxies:
  - name: ByeDPI Local
    type: byedpi
    mode: manual
    args: "--disorder 1 --auto=torst --tlsrec 1+s"
''');

      expect(normalized['proxies'][0]['type'], 'socks5');
      expect(normalized['proxies'][0]['server'], '127.0.0.1');
      expect(normalized['proxies'][0]['port'], inInclusiveRange(35600, 35855));
    });

    test('accepts the minimal ByeDPI auto contract', () {
      final normalized = validator.normalizeForValidation('''
proxies:
  - name: ByeDPI Auto
    type: byedpi
''');

      expect(normalized['proxies'][0]['type'], 'socks5');
      expect(normalized['proxies'][0]['server'], '127.0.0.1');
    });

    test('infers manual ByeDPI mode from args for compatibility', () {
      final normalized = validator.normalizeForValidation('''
proxies:
  - name: ByeDPI
    type: byedpi
    args: "--fake -1"
''');

      expect(normalized['proxies'][0]['type'], 'socks5');
      expect(normalized['proxies'][0]['server'], '127.0.0.1');
    });

    test('rejects byedpi local listener overrides', () {
      expect(
        () => validator.normalizeForValidation('''
proxies:
  - name: ByeDPI Bad
    type: byedpi
    mode: manual
    args: "--fake -1"
    port: 1080
'''),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('must not override'),
          ),
        ),
      );
    });
  });
}
