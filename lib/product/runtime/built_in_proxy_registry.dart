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
            availability: BuiltInProxyAvailability.unsupported(
              reason:
                  'byedpi process packaging, lifecycle supervision, and client-owned local-node contract are not integrated yet.',
              updatePath:
                  'Ship a pinned Android binary plus node-specific config/start/health contracts before enabling `type: byedpi`.',
              rollbackPath:
                  'Reject the node at compile time and keep the profile on the single-engine mihomo path until the contract is versioned.',
            ),
          ),
          BuiltInProxyType.olcrtc: BuiltInProxyDescriptor(
            type: BuiltInProxyType.olcrtc,
            protocol: BuiltInProxyProtocol.socks5,
            supportsUdp: false,
            listenPortRangeStart: 35900,
            listenPortRangeSize: 256,
            availability: BuiltInProxyAvailability.unsupported(
              reason:
                  'olcrtc Android packaging, gomobile bridge, and node-local config/lifecycle contracts are not integrated yet.',
              updatePath:
                  'Ship a pinned Android runtime plus Start/Stop/health contracts before enabling `type: olcrtc`.',
              rollbackPath:
                  'Reject the node at compile time and keep traffic on mihomo until the local-node integration is versioned.',
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
