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
        'provider': provider,
        if (provider != 'none') 'room': 'room-id',
        if (provider == 'none') ...{
          'engine': 'jitsi',
          'engine-url': 'https://meet.example.org',
          'engine-token': 'token',
        },
        'encryption-key': key,
        'transport': transport,
        if (dns != null) 'dns-server': dns,
        if (transport != 'datachannel')
          'transport-options': switch (transport) {
            'vp8channel' => {'fps': 30, 'batch-size': 64},
            'seichannel' => {
                'fps': 30,
                'batch-size': 64,
                'fragment-size': 900,
                'ack-timeout': '2s',
              },
            'videochannel' => {
                'width': 1920,
                'height': 1080,
                'fps': 30,
                'bitrate': '2M',
              },
            _ => <String, dynamic>{},
          },
      };

  test('accepts every provider and transport supported by pinned OlcRTC', () {
    for (final provider in OlcRtcConfigValidator.supportedProviders) {
      for (final transport in OlcRtcConfigValidator.supportedTransports) {
        final value = config(provider: provider, transport: transport);
        expect(() => validator.validate(value), returnsNormally);
      }
    }
  });

  test('rejects missing and malformed DNS endpoints', () {
    expect(
      () => validator.validate(config(dns: null)),
      throwsA(isA<FormatException>()),
    );
    for (final dns in ['1.1.1.1', '1.1.1.1:0', '1.1.1.1:65536', ':53']) {
      expect(
        () => validator.validate(config(dns: dns)),
        throwsA(isA<FormatException>()),
      );
    }
    expect(
      () => validator.validate(config(dns: '[2001:4860:4860::8888]:53')),
      returnsNormally,
    );
  });

  test('rejects malformed keys and provider-engine mismatches', () {
    expect(
      () => validator.validate(config()..['encryption-key'] = 'not-a-key'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => validator.validate(config()..['engine'] = 'jitsi'),
      throwsA(isA<FormatException>()),
    );
    final direct = config(provider: 'none')..remove('engine-token');
    expect(
      () => validator.validate(direct),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects irrelevant transport fields and invalid durations', () {
    expect(
      () => validator.validate(
        config(transport: 'datachannel')..['transport-options'] = {'fps': 30},
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => validator.validate(
        config(transport: 'seichannel')
          ..['transport-options'] = {
            'fps': 30,
            'batch-size': 64,
            'fragment-size': 900,
            'ack-timeout': '-1s',
          },
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => validator.validate(
        config(transport: 'videochannel')
          ..['transport-options'] = {
            'codec': 'tile',
            'width': 1920,
            'height': 1080,
          },
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
