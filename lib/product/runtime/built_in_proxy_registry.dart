import 'built_in_proxy_types.dart';

const builtInProxyRegistry = BuiltInProxyRegistry.flClashM();

class BuiltInProxyRegistry {
  const BuiltInProxyRegistry.flClashM()
      : _descriptors = const {
          BuiltInProxyType.naiveproxy: BuiltInProxyDescriptor(
            type: BuiltInProxyType.naiveproxy,
            protocol: BuiltInProxyProtocol.socks5,
            supportsUdp: false,
            supportsActivation: false,
            defaultUdp: false,
            listenPortRangeStart: 35000,
            listenPortRangeSize: 512,
            availability: BuiltInProxyAvailability.supported(
              updatePath:
                  'setup.dart extracts the pinned stable naiveproxy plugin APK into bundled Android assets, and Android runs the immutable native library from nativeLibraryDir.',
              rollbackPath:
                  'Profile apply failures roll node configs and processes back to the last committed runtime plan; the bundled Android native library itself is not swapped at runtime.',
            ),
          ),
          BuiltInProxyType.byedpi: BuiltInProxyDescriptor(
            type: BuiltInProxyType.byedpi,
            protocol: BuiltInProxyProtocol.socks5,
            supportsUdp: true,
            supportsActivation: false,
            defaultUdp: true,
            listenPortRangeStart: 35600,
            listenPortRangeSize: 256,
            availability: BuiltInProxyAvailability.supported(
              updatePath:
                  'setup.dart builds the pinned byedpi Android executable from source, bundles the pinned ByeByeDPI strategy list, and Android runs the immutable native library from nativeLibraryDir.',
              rollbackPath:
                  'Failed profile apply rolls node configs and processes back to the last committed runtime plan; the bundled Android native library itself is not swapped at runtime.',
            ),
          ),
          BuiltInProxyType.olcrtc: BuiltInProxyDescriptor(
            type: BuiltInProxyType.olcrtc,
            protocol: BuiltInProxyProtocol.socks5,
            supportsUdp: false,
            supportsActivation: true,
            defaultUdp: false,
            listenPortRangeStart: 35900,
            listenPortRangeSize: 256,
            availability: BuiltInProxyAvailability.supported(
              updatePath:
                  'setup.dart builds the pinned olcrtc Android executable from source into bundled Android assets, and Android runs the immutable native library from nativeLibraryDir.',
              rollbackPath:
                  'Failed profile apply rolls node configs and processes back to the last committed runtime plan; the bundled Android native library itself is not swapped at runtime.',
            ),
          ),
          BuiltInProxyType.stormdns: BuiltInProxyDescriptor(
            type: BuiltInProxyType.stormdns,
            protocol: BuiltInProxyProtocol.socks5,
            supportsUdp: false,
            supportsActivation: true,
            defaultUdp: false,
            listenPortRangeStart: 36200,
            listenPortRangeSize: 256,
            // A cold start performs an MTU scan before opening the listener.
            // It took 28 seconds with three resolvers on a real Android device.
            defaultStartupTimeout: Duration(minutes: 2),
            availability: BuiltInProxyAvailability.supported(
              updatePath:
                  'setup.dart builds the pinned stormdns Android executable from source into bundled Android assets, and Android runs the immutable native library from nativeLibraryDir.',
              rollbackPath:
                  'Failed profile apply rolls node configs, resolver files, and processes back to the last committed runtime plan; the bundled Android native library itself is not swapped at runtime.',
            ),
          ),
        };

  final Map<BuiltInProxyType, BuiltInProxyDescriptor> _descriptors;

  Iterable<BuiltInProxyDescriptor> get descriptors => _descriptors.values;

  BuiltInProxyDescriptor descriptorFor(BuiltInProxyType type) {
    final descriptor = _descriptors[type];
    if (descriptor == null) {
      throw ArgumentError('Built-in proxy `${type.label}` is not registered.');
    }
    return descriptor;
  }

  BuiltInProxyDescriptor resolveSupported(BuiltInProxyType type) {
    final descriptor = descriptorFor(type);
    if (!descriptor.availability.isSupported) {
      throw UnsupportedBuiltInProxyException(
        buildUnsupportedMessage(descriptor),
      );
    }
    return descriptor;
  }

  String buildUnsupportedMessage(BuiltInProxyDescriptor descriptor) =>
      '${descriptor.type.label} built-in node is not available: '
      '${descriptor.availability.reason} '
      'Update path: ${descriptor.availability.updatePath} '
      'Rollback path: ${descriptor.availability.rollbackPath}';
}
