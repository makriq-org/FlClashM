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

    test('resolves byedpi as a supported built-in node type', () {
      final descriptor = builtInProxyRegistry.resolveSupported(
        BuiltInProxyType.byedpi,
      );

      expect(descriptor.type, BuiltInProxyType.byedpi);
      expect(descriptor.protocol, BuiltInProxyProtocol.socks5);
      expect(descriptor.availability.isSupported, isTrue);
    });

    test('resolves olcrtc as a supported built-in node type', () {
      final descriptor = builtInProxyRegistry.resolveSupported(
        BuiltInProxyType.olcrtc,
      );

      expect(descriptor.type, BuiltInProxyType.olcrtc);
      expect(descriptor.protocol, BuiltInProxyProtocol.socks5);
      expect(descriptor.availability.isSupported, isTrue);
    });
  });
}
