import 'built_in_proxy_types.dart';

const builtInProxyRegistry = BuiltInProxyRegistry.flClashM();

class BuiltInProxyRegistry {
  const BuiltInProxyRegistry.flClashM()
      : _descriptors = const {
          BuiltInProxyType.naiveproxy: BuiltInProxyDescriptor(
            type: BuiltInProxyType.naiveproxy,
            protocol: BuiltInProxyProtocol.socks5,
            supportsUdp: false,
            listenPortRangeStart: 35000,
            listenPortRangeSize: 512,
            availability: BuiltInProxyAvailability.supported(
              updatePath:
                  'setup.dart extracts the pinned stable naiveproxy plugin APK into bundled Android assets, then runtime activation swaps the shared binary through .pending in app data.',
              rollbackPath:
                  'Failed pending activation restores the previous shared binary, keeps .pending for retry, and rolls node configs/processes back to the last committed runtime plan.',
            ),
          ),
          BuiltInProxyType.byedpi: BuiltInProxyDescriptor(
            type: BuiltInProxyType.byedpi,
            protocol: BuiltInProxyProtocol.socks5,
            supportsUdp: false,
            listenPortRangeStart: 35600,
            listenPortRangeSize: 256,
            availability: BuiltInProxyAvailability.supported(
              updatePath:
                  'setup.dart builds the pinned byedpi Android executable from source and bundles the pinned ByeByeDPI strategy list; runtime activation swaps the shared binary through .pending in app data.',
              rollbackPath:
                  'Failed pending activation restores the previous executable, keeps .pending for retry, and failed profile apply rolls node configs/processes back to the last committed runtime plan.',
            ),
          ),
          BuiltInProxyType.olcrtc: BuiltInProxyDescriptor(
            type: BuiltInProxyType.olcrtc,
            protocol: BuiltInProxyProtocol.socks5,
            supportsUdp: false,
            listenPortRangeStart: 35900,
            listenPortRangeSize: 256,
            availability: BuiltInProxyAvailability.supported(
              updatePath:
                  'setup.dart builds the pinned olcrtc Android executable from source into bundled Android assets, then runtime activation swaps the shared binary through .pending in app data.',
              rollbackPath:
                  'Failed pending activation restores the previous shared binary, keeps .pending for retry, and rolls node configs/processes back to the last committed runtime plan.',
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
