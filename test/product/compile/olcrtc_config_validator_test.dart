import 'package:flclashx/product/compile/product_compile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const validator = OlcRtcConfigValidator();
  const key =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  Map<String, dynamic> config({
    String provider = 'wbstream',
    String transport = 'vp8channel',
    Object? dns = '1.1.1.1:53',
  }) =>
      {
        'auth': {'provider': provider},
        'room': {'id': 'room-id'},
        'crypto': {'key': key},
        'net': {
          'transport': transport,
          if (dns != null) 'dns': dns,
        },
        'vp8': {'fps': 30, 'batch_size': 64},
      };

  test('accepts every provider and transport supported by pinned OlcRTC', () {
    for (final provider in OlcRtcConfigValidator.supportedProviders) {
      for (final transport in OlcRtcConfigValidator.supportedTransports) {
        final value = config(provider: provider, transport: transport);
        if (provider == 'none') {
          value['room'] = <String, dynamic>{};
        }
        expect(() => validator.validate(value), returnsNormally,
            reason: '$provider/$transport');
      }
    }
  });

  test('rejects a missing DNS server before starting OlcRTC', () {
    expect(
      () => validator.validate(config(dns: null)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('olcrtc.net.dns'),
        ),
      ),
    );
  });

  test('rejects malformed DNS endpoints', () {
    for (final dns in ['1.1.1.1', '1.1.1.1:0', '1.1.1.1:65536', ':53']) {
      expect(
        () => validator.validate(config(dns: dns)),
        throwsA(isA<FormatException>()),
        reason: dns,
      );
    }
    expect(
      () => validator.validate(config(dns: '[2001:4860:4860::8888]:53')),
      returnsNormally,
    );
  });

  test('rejects malformed keys and unsupported selections', () {
    final badKey = config()..['crypto'] = {'key': 'not-a-key'};
    final badProvider = config(provider: 'unknown');
    final badTransport = config(transport: 'unknown');
    final paddedKey = config()..['crypto'] = {'key': ' $key'};
    final uppercaseProvider = config(provider: 'WBSTREAM');

    expect(() => validator.validate(badKey), throwsA(isA<FormatException>()));
    expect(
        () => validator.validate(badProvider), throwsA(isA<FormatException>()));
    expect(() => validator.validate(badTransport),
        throwsA(isA<FormatException>()));
    expect(
        () => validator.validate(paddedKey), throwsA(isA<FormatException>()));
    expect(() => validator.validate(uppercaseProvider),
        throwsA(isA<FormatException>()));
  });

  test('validates effective failover profiles with inherited defaults', () {
    final value = config()
      ..['profiles'] = [
        {
          'name': 'wb-vp8',
          'room': {'id': 'wb-room'},
          'vp8': {'fps': 0, 'batch_size': 0},
        },
        {
          'name': 'jitsi-dc',
          'auth': {'provider': 'jitsi'},
          'room': {'id': 'https://meet.example.org/room'},
          'net': {'transport': 'datachannel'},
        },
      ];

    expect(() => validator.validate(value), returnsNormally);
  });

  test('rejects invalid section types and profile entries', () {
    expect(
      () => validator.validate(config()..['net'] = 'vp8channel'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => validator.validate(config()..['profiles'] = ['invalid']),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects invalid transport parameters and durations', () {
    expect(
      () => validator.validate(config()..['vp8'] = {'fps': 0}),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => validator.validate(config()..['liveness'] = {'interval': '-1s'}),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => validator.validate(
        config()
          ..['net'] = {
            'transport': 'videochannel',
            'dns': '1.1.1.1:53',
          }
          ..['video'] = {
            'codec': 'tile',
            'width': 1920,
            'height': 1080,
          },
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => validator.validate(
        config()
          ..['traffic'] = {
            'min_delay': '30ms',
            'max_delay': '5ms',
          },
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
