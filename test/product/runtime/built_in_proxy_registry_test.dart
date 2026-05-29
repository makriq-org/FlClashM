import 'package:flclashx/product/runtime/product_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BuiltInProxyRegistry', () {
    test('resolves naiveproxy as the supported built-in node type', () {
      final descriptor = builtInProxyRegistry.resolveSupported(
        BuiltInProxyType.naiveproxy,
      );

      expect(descriptor.type, BuiltInProxyType.naiveproxy);
      expect(descriptor.protocol, BuiltInProxyProtocol.socks5);
      expect(descriptor.availability.isSupported, isTrue);
    });

    test('rejects byedpi until node integration exists', () {
      expect(
        () => builtInProxyRegistry.resolveSupported(BuiltInProxyType.byedpi),
        throwsA(
          isA<UnsupportedBuiltInProxyException>().having(
            (error) => error.message,
            'message',
            contains('byedpi built-in node is not available'),
          ),
        ),
      );
    });

    test('rejects olcrtc until node integration exists', () {
      expect(
        () => builtInProxyRegistry.resolveSupported(BuiltInProxyType.olcrtc),
        throwsA(
          isA<UnsupportedBuiltInProxyException>().having(
            (error) => error.message,
            'message',
            contains('olcrtc built-in node is not available'),
          ),
        ),
      );
    });
  });
}
