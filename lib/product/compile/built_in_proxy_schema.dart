import 'package:flutter/foundation.dart';

import '../runtime/built_in_proxy_types.dart';
import '../runtime/byedpi_release.dart';
import '../runtime/naiveproxy_release.dart';
import '../runtime/olcrtc_release.dart';
import '../runtime/stormdns_release.dart';

enum ConfigValueType { string, boolean, integer, number, object, list }

@immutable
class ConfigValueRange {
  const ConfigValueRange({
    this.minimum,
    this.maximum,
    this.exclusiveMinimum = false,
  });

  final num? minimum;
  final num? maximum;
  final bool exclusiveMinimum;
}

@immutable
class ConfigDefaultValue {
  const ConfigDefaultValue.absent()
      : isSpecified = false,
        value = null;

  const ConfigDefaultValue.of(this.value) : isSpecified = true;

  final bool isSpecified;
  final Object? value;
}

@immutable
class BuiltInProxyFieldSchema {
  const BuiltInProxyFieldSchema({
    required this.path,
    required this.type,
    this.additionalTypes = const <ConfigValueType>{},
    this.required = false,
    this.modes = const <String>{},
    this.allowedValues = const <Object>{},
    this.range = const ConfigValueRange(),
    this.defaultValue = const ConfigDefaultValue.absent(),
    this.forbiddenReason,
  });

  final String path;
  final ConfigValueType type;
  final Set<ConfigValueType> additionalTypes;
  final bool required;
  final Set<String> modes;
  final Set<Object> allowedValues;
  final ConfigValueRange range;
  final ConfigDefaultValue defaultValue;
  final String? forbiddenReason;
}

@immutable
class BuiltInProxySchema {
  const BuiltInProxySchema({
    required this.type,
    required this.runtimeVersion,
    required this.fields,
  });

  final BuiltInProxyType type;
  final String runtimeVersion;
  final List<BuiltInProxyFieldSchema> fields;
}

const _commonFields = <BuiltInProxyFieldSchema>[
  BuiltInProxyFieldSchema(
    path: 'common.name',
    type: ConfigValueType.string,
    required: true,
  ),
  BuiltInProxyFieldSchema(
    path: 'common.type',
    type: ConfigValueType.string,
    required: true,
  ),
  BuiltInProxyFieldSchema(path: 'common.udp', type: ConfigValueType.boolean),
  BuiltInProxyFieldSchema(
    path: 'common.connectivity-check',
    type: ConfigValueType.object,
  ),
  BuiltInProxyFieldSchema(
    path: 'common.connectivity-check.urls',
    type: ConfigValueType.list,
    defaultValue: ConfigDefaultValue.of(<String>[]),
  ),
  BuiltInProxyFieldSchema(
    path: 'common.connectivity-check.urls[]',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(
    path: 'common.connectivity-check.required',
    type: ConfigValueType.boolean,
    defaultValue: ConfigDefaultValue.of(false),
  ),
  BuiltInProxyFieldSchema(
    path: 'common.connectivity-check.timeout',
    type: ConfigValueType.string,
    additionalTypes: <ConfigValueType>{ConfigValueType.integer},
    defaultValue: ConfigDefaultValue.of('5s'),
  ),
  BuiltInProxyFieldSchema(
    path: 'common.connectivity-check.startup-timeout',
    type: ConfigValueType.string,
    additionalTypes: <ConfigValueType>{ConfigValueType.integer},
    defaultValue: ConfigDefaultValue.of('30s'),
  ),
  BuiltInProxyFieldSchema(
    path: 'common.connectivity-check.retry-interval',
    type: ConfigValueType.string,
    additionalTypes: <ConfigValueType>{ConfigValueType.integer},
    defaultValue: ConfigDefaultValue.of('1s'),
  ),
  BuiltInProxyFieldSchema(
    path: 'common.connectivity-check.requests',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1, maximum: 32),
    defaultValue: ConfigDefaultValue.of(1),
  ),
  BuiltInProxyFieldSchema(
    path: 'common.connectivity-check.concurrency',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1, maximum: 16),
    defaultValue: ConfigDefaultValue.of(1),
  ),
  BuiltInProxyFieldSchema(
    path: 'common.connectivity-check.min-success-ratio',
    type: ConfigValueType.number,
    range: ConfigValueRange(minimum: 0, maximum: 1, exclusiveMinimum: true),
  ),
];

List<BuiltInProxyFieldSchema> _forType(
  String type,
  List<BuiltInProxyFieldSchema> fields,
) =>
    <BuiltInProxyFieldSchema>[
      for (final field in _commonFields)
        BuiltInProxyFieldSchema(
          path: field.path.replaceFirst('common', type),
          type: field.type,
          additionalTypes: field.additionalTypes,
          required: field.required,
          modes: field.modes,
          allowedValues: field.path == 'common.type'
              ? <Object>{type}
              : field.allowedValues,
          range: field.range,
          defaultValue: field.defaultValue,
          forbiddenReason: field.forbiddenReason,
        ),
      ...fields,
    ];

final builtInProxySchemas = <BuiltInProxyType, BuiltInProxySchema>{
  BuiltInProxyType.naiveproxy: BuiltInProxySchema(
    type: BuiltInProxyType.naiveproxy,
    runtimeVersion: naiveProxyPinnedReleaseTag,
    fields: _forType('naiveproxy', const <BuiltInProxyFieldSchema>[
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.server',
        type: ConfigValueType.string,
        required: true,
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.port',
        type: ConfigValueType.integer,
        required: true,
        range: ConfigValueRange(minimum: 1, maximum: 65535),
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.username',
        type: ConfigValueType.string,
        required: true,
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.password',
        type: ConfigValueType.string,
        required: true,
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.transport',
        type: ConfigValueType.string,
        allowedValues: <Object>{'https', 'quic'},
        defaultValue: ConfigDefaultValue.of('https'),
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.insecure-concurrency',
        type: ConfigValueType.integer,
        range: ConfigValueRange(minimum: 1, maximum: 4),
        defaultValue: ConfigDefaultValue.of(1),
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.tunnel-timeout',
        type: ConfigValueType.string,
        additionalTypes: <ConfigValueType>{ConfigValueType.integer},
        defaultValue: ConfigDefaultValue.of('10m'),
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.idle-timeout',
        type: ConfigValueType.string,
        additionalTypes: <ConfigValueType>{ConfigValueType.integer},
        defaultValue: ConfigDefaultValue.of('5m'),
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.post-quantum',
        type: ConfigValueType.boolean,
        defaultValue: ConfigDefaultValue.of(true),
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.headers',
        type: ConfigValueType.object,
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.host-resolver-rules',
        type: ConfigValueType.string,
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.proxy',
        type: ConfigValueType.string,
        forbiddenReason:
            '`proxy` is not supported; proxy URIs and chains are not part of the user contract',
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.listen',
        type: ConfigValueType.string,
        forbiddenReason: 'the local listener is owned by FlClashM',
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.log',
        type: ConfigValueType.string,
        forbiddenReason: 'user-selected output paths are not supported',
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.log-net-log',
        type: ConfigValueType.string,
        forbiddenReason: 'user-selected output paths are not supported',
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.ssl-key-log-file',
        type: ConfigValueType.string,
        forbiddenReason: 'TLS key logging is not supported',
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.no-post-quantum',
        type: ConfigValueType.boolean,
        forbiddenReason:
            'users must configure `post-quantum`; the native inverse flag is generated by FlClashM',
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.resolver-range',
        type: ConfigValueType.string,
        forbiddenReason: 'resolver ranges are not part of the user contract',
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.extra-headers',
        type: ConfigValueType.string,
        forbiddenReason:
            'users must configure `headers`, which FlClashM encodes as `extra-headers`',
      ),
    ]),
  ),
  BuiltInProxyType.byedpi: BuiltInProxySchema(
    type: BuiltInProxyType.byedpi,
    runtimeVersion: byedpiPinnedReleaseTag,
    fields: _forType('byedpi', const <BuiltInProxyFieldSchema>[
      BuiltInProxyFieldSchema(
        path: 'byedpi.mode',
        type: ConfigValueType.string,
        allowedValues: <Object>{'manual', 'auto'},
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy',
        type: ConfigValueType.string,
        required: true,
        modes: <String>{'manual'},
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategies',
        type: ConfigValueType.list,
        modes: <String>{'auto'},
        defaultValue: ConfigDefaultValue.of(<String>['builtin:byebyeedpi']),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategies[]',
        type: ConfigValueType.string,
        modes: <String>{'auto'},
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-test',
        type: ConfigValueType.object,
        modes: <String>{'auto'},
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-test.urls',
        type: ConfigValueType.list,
        modes: <String>{'auto'},
        defaultValue: ConfigDefaultValue.of(<String>[
          'https://youtube.com/generate_204',
        ]),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-test.urls[]',
        type: ConfigValueType.string,
        modes: <String>{'auto'},
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-test.sni',
        type: ConfigValueType.string,
        modes: <String>{'auto'},
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-test.dns-resolver',
        type: ConfigValueType.string,
        modes: <String>{'auto'},
        defaultValue: ConfigDefaultValue.of('https://1.1.1.1/dns-query'),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-test.timeout',
        type: ConfigValueType.string,
        additionalTypes: <ConfigValueType>{ConfigValueType.integer},
        modes: <String>{'auto'},
        defaultValue: ConfigDefaultValue.of('5s'),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-test.requests',
        type: ConfigValueType.integer,
        modes: <String>{'auto'},
        range: ConfigValueRange(minimum: 1, maximum: 32),
        defaultValue: ConfigDefaultValue.of(1),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-test.request-concurrency',
        type: ConfigValueType.integer,
        modes: <String>{'auto'},
        range: ConfigValueRange(minimum: 1, maximum: 16),
        defaultValue: ConfigDefaultValue.of(4),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-test.min-success-ratio',
        type: ConfigValueType.number,
        modes: <String>{'auto'},
        range: ConfigValueRange(minimum: 0, maximum: 1, exclusiveMinimum: true),
        defaultValue: ConfigDefaultValue.of(1.0),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-selection',
        type: ConfigValueType.object,
        modes: <String>{'auto'},
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-selection.strategy-concurrency',
        type: ConfigValueType.integer,
        modes: <String>{'auto'},
        range: ConfigValueRange(minimum: 1, maximum: 16),
        defaultValue: ConfigDefaultValue.of(4),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-selection.startup-timeout',
        type: ConfigValueType.string,
        additionalTypes: <ConfigValueType>{ConfigValueType.integer},
        modes: <String>{'auto'},
        defaultValue: ConfigDefaultValue.of('15s'),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-selection.continue-in-background',
        type: ConfigValueType.boolean,
        modes: <String>{'auto'},
        defaultValue: ConfigDefaultValue.of(true),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-selection.fallback-strategy',
        type: ConfigValueType.string,
        modes: <String>{'auto'},
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-selection.retry-after',
        type: ConfigValueType.string,
        additionalTypes: <ConfigValueType>{ConfigValueType.integer},
        modes: <String>{'auto'},
        defaultValue: ConfigDefaultValue.of('5m'),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-selection.cache',
        type: ConfigValueType.object,
        modes: <String>{'auto'},
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-selection.cache.ttl',
        type: ConfigValueType.string,
        additionalTypes: <ConfigValueType>{ConfigValueType.integer},
        modes: <String>{'auto'},
        defaultValue: ConfigDefaultValue.of('7d'),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-selection.cache.recheck-after',
        type: ConfigValueType.string,
        additionalTypes: <ConfigValueType>{ConfigValueType.integer},
        modes: <String>{'auto'},
        defaultValue: ConfigDefaultValue.of('1d'),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-selection.cache.failure-threshold',
        type: ConfigValueType.integer,
        modes: <String>{'auto'},
        range: ConfigValueRange(minimum: 1, maximum: 32),
        defaultValue: ConfigDefaultValue.of(2),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.test',
        type: ConfigValueType.object,
        forbiddenReason: 'rename it to strategy-test',
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.listen',
        type: ConfigValueType.string,
        forbiddenReason: 'the local listener is owned by FlClashM',
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.server',
        type: ConfigValueType.string,
        forbiddenReason: 'the local listener is owned by FlClashM',
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.ip',
        type: ConfigValueType.string,
        forbiddenReason: 'the local listener address is owned by FlClashM',
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.port',
        type: ConfigValueType.integer,
        forbiddenReason: 'the local listener port is owned by FlClashM',
      ),
    ]),
  ),
  BuiltInProxyType.olcrtc: BuiltInProxySchema(
    type: BuiltInProxyType.olcrtc,
    runtimeVersion: olcRtcPinnedReleaseTag,
    fields: _forType('olcrtc', _canonicalOlcRtcFields),
  ),
  BuiltInProxyType.stormdns: BuiltInProxySchema(
    type: BuiltInProxyType.stormdns,
    runtimeVersion: stormDnsPinnedReleaseTag,
    fields: _forType('stormdns', _stormDnsFields),
  ),
};

const _canonicalOlcRtcFields = <BuiltInProxyFieldSchema>[
  ..._canonicalActivationFields,
  BuiltInProxyFieldSchema(
    path: 'olcrtc.provider',
    type: ConfigValueType.string,
    required: true,
    allowedValues: <Object>{'jitsi', 'telemost', 'wbstream', 'none'},
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.provider-token',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(path: 'olcrtc.room', type: ConfigValueType.string),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.room-channel',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.encryption-key',
    type: ConfigValueType.string,
    required: true,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.transport',
    type: ConfigValueType.string,
    required: true,
    allowedValues: <Object>{
      'datachannel',
      'videochannel',
      'seichannel',
      'vp8channel',
    },
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.dns-server',
    type: ConfigValueType.string,
    required: true,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.engine',
    type: ConfigValueType.string,
    allowedValues: <Object>{'livekit', 'goolom', 'jitsi'},
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.engine-url',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.engine-token',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.transport-options',
    type: ConfigValueType.object,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.transport-options.codec',
    type: ConfigValueType.string,
    allowedValues: <Object>{'qrcode', 'tile'},
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.transport-options.width',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.transport-options.height',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.transport-options.fps',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.transport-options.bitrate',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.transport-options.batch-size',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.transport-options.fragment-size',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.transport-options.ack-timeout',
    type: ConfigValueType.string,
    additionalTypes: <ConfigValueType>{ConfigValueType.integer},
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.transport-options.qr-recovery',
    type: ConfigValueType.string,
    allowedValues: <Object>{'low', 'medium', 'quartile', 'high', 'highest'},
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.transport-options.tile-module',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 0),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.transport-options.tile-rs',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 0),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.liveness',
    type: ConfigValueType.object,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.liveness.interval',
    type: ConfigValueType.string,
    defaultValue: ConfigDefaultValue.of('10s'),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.liveness.timeout',
    type: ConfigValueType.string,
    defaultValue: ConfigDefaultValue.of('15s'),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.liveness.failures',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 0),
    defaultValue: ConfigDefaultValue.of(4),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.lifecycle',
    type: ConfigValueType.object,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.lifecycle.max-session-duration',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(path: 'olcrtc.traffic', type: ConfigValueType.object),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.traffic.max-payload-size',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 0),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.traffic.min-delay',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.traffic.max-delay',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(path: 'olcrtc.debug', type: ConfigValueType.boolean),
];

const _canonicalActivationFields = <BuiltInProxyFieldSchema>[
  BuiltInProxyFieldSchema(
    path: 'olcrtc.activation',
    type: ConfigValueType.string,
    additionalTypes: <ConfigValueType>{ConfigValueType.object},
    allowedValues: <Object>{'auto', 'always'},
    defaultValue: ConfigDefaultValue.of('auto'),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.mode',
    type: ConfigValueType.string,
    allowedValues: <Object>{'auto', 'always'},
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.wake',
    type: ConfigValueType.object,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.wake.urls',
    type: ConfigValueType.list,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.wake.urls[]',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.wake.interval',
    type: ConfigValueType.string,
    additionalTypes: <ConfigValueType>{ConfigValueType.integer},
    defaultValue: ConfigDefaultValue.of('30s'),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.wake.failures',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1, maximum: 10),
    defaultValue: ConfigDefaultValue.of(2),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.wake.retry-after',
    type: ConfigValueType.string,
    additionalTypes: <ConfigValueType>{ConfigValueType.integer},
    defaultValue: ConfigDefaultValue.of('5m'),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.sleep',
    type: ConfigValueType.object,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.sleep.idle',
    type: ConfigValueType.string,
    additionalTypes: <ConfigValueType>{ConfigValueType.integer},
    defaultValue: ConfigDefaultValue.of('15m'),
  ),
];

/// Encryption methods StormDNS accepts, in `DATA_ENCRYPTION_METHOD` order.
///
/// `none` and `xor` are deliberately allowed: they are part of the upstream
/// contract and some servers are configured that way. They do not hide payload
/// contents from the resolver operator, which the documentation states.
const stormDnsEncryptionMethods = <String, int>{
  'none': 0,
  'xor': 1,
  'chacha20': 2,
  'aes-128-gcm': 3,
  'aes-192-gcm': 4,
  'aes-256-gcm': 5,
};

/// Compression algorithms in `UPLOAD_COMPRESSION_TYPE` order.
const stormDnsCompressionTypes = <String, int>{
  'none': 0,
  'zstd': 1,
  'lz4': 2,
  'zlib': 3,
};

/// Resolver balancing strategies in `RESOLVER_BALANCING_STRATEGY` order.
const stormDnsResolverStrategies = <String, int>{
  'random': 1,
  'round-robin': 2,
  'least-loss': 3,
  'lowest-latency': 4,
};

/// Startup modes translated to `STARTUP_MODE` plus `LOG_BASED_MTU_VERIFY`.
const stormDnsStartupModes = <String, ({String mode, bool verifyMtu})>{
  'scan': (mode: 'resolvers', verifyMtu: false),
  'cached': (mode: 'logs', verifyMtu: false),
  'verified': (mode: 'logs', verifyMtu: true),
};

/// Duplication and compression defaults applied by each preset, before any
/// explicitly configured field wins. Order: upload, download, upload-setup,
/// download-setup.
const stormDnsPresets = <String, StormDnsPreset>{
  'messenger': StormDnsPreset(
    duplication: (upload: 1, download: 7, uploadSetup: 3, downloadSetup: 8),
    compression: 'lz4',
  ),
  'balanced': StormDnsPreset(
    duplication: (upload: 2, download: 5, uploadSetup: 3, downloadSetup: 6),
    compression: 'lz4',
  ),
  'bulk': StormDnsPreset(
    duplication: (upload: 3, download: 3, uploadSetup: 4, downloadSetup: 4),
    compression: 'zstd',
  ),
};

@immutable
class StormDnsPreset {
  const StormDnsPreset({required this.duplication, required this.compression});

  final ({
    int upload,
    int download,
    int uploadSetup,
    int downloadSetup
  }) duplication;
  final String compression;
}

List<BuiltInProxyFieldSchema> _activationFields(String prefix) => [
      BuiltInProxyFieldSchema(
        path: '$prefix.activation',
        type: ConfigValueType.string,
        additionalTypes: const <ConfigValueType>{ConfigValueType.object},
        allowedValues: const <Object>{'auto', 'always'},
        defaultValue: const ConfigDefaultValue.of('auto'),
      ),
      BuiltInProxyFieldSchema(
        path: '$prefix.activation.mode',
        type: ConfigValueType.string,
        allowedValues: const <Object>{'auto', 'always'},
        defaultValue: const ConfigDefaultValue.of('auto'),
      ),
      BuiltInProxyFieldSchema(
        path: '$prefix.activation.wake',
        type: ConfigValueType.object,
      ),
      BuiltInProxyFieldSchema(
        path: '$prefix.activation.wake.urls',
        type: ConfigValueType.list,
        defaultValue: const ConfigDefaultValue.of(<String>[]),
      ),
      BuiltInProxyFieldSchema(
        path: '$prefix.activation.wake.urls[]',
        type: ConfigValueType.string,
      ),
      BuiltInProxyFieldSchema(
        path: '$prefix.activation.wake.interval',
        type: ConfigValueType.string,
        additionalTypes: const <ConfigValueType>{ConfigValueType.integer},
        defaultValue: const ConfigDefaultValue.of('30s'),
      ),
      BuiltInProxyFieldSchema(
        path: '$prefix.activation.wake.failures',
        type: ConfigValueType.integer,
        range: const ConfigValueRange(minimum: 1, maximum: 10),
        defaultValue: const ConfigDefaultValue.of(2),
      ),
      BuiltInProxyFieldSchema(
        path: '$prefix.activation.wake.retry-after',
        type: ConfigValueType.string,
        additionalTypes: const <ConfigValueType>{ConfigValueType.integer},
        defaultValue: const ConfigDefaultValue.of('5m'),
      ),
      BuiltInProxyFieldSchema(
        path: '$prefix.activation.sleep',
        type: ConfigValueType.object,
      ),
      BuiltInProxyFieldSchema(
        path: '$prefix.activation.sleep.idle',
        type: ConfigValueType.string,
        additionalTypes: const <ConfigValueType>{ConfigValueType.integer},
        defaultValue: const ConfigDefaultValue.of('15m'),
      ),
    ];
const stormDnsDurationRanges = <String, ({String min, String max})>{
  'arq.initial-rto': (min: '50ms', max: '60s'),
  'arq.max-rto': (min: '50ms', max: '120s'),
  'arq.control-initial-rto': (min: '50ms', max: '60s'),
  'arq.control-max-rto': (min: '50ms', max: '120s'),
  'arq.inactivity-timeout': (min: '30s', max: '24h'),
  'arq.data-packet-ttl': (min: '30s', max: '24h'),
  'arq.control-packet-ttl': (min: '30s', max: '24h'),
  'arq.nack-initial-delay': (min: '50ms', max: '30s'),
  'arq.nack-repeat': (min: '80ms', max: '30s'),
  'arq.terminal-drain-timeout': (min: '10s', max: '1h'),
  'arq.terminal-ack-wait-timeout': (min: '5s', max: '1h'),
  'ping.aggressive-interval': (min: '50ms', max: '30s'),
  'ping.lazy-interval': (min: '50ms', max: '60s'),
  'ping.cooldown-interval': (min: '50ms', max: '300s'),
  'ping.cold-interval': (min: '50ms', max: '1h'),
  'ping.warm-threshold': (min: '100ms', max: '600s'),
  'ping.cool-threshold': (min: '100ms', max: '1800s'),
  'ping.cold-threshold': (min: '100ms', max: '1h'),
  'ping.watchdog-timeout': (min: '10s', max: '1h'),
  'runtime.packet-timeout': (min: '500ms', max: '120s'),
  'runtime.idle-poll-interval': (min: '1ms', max: '1s'),
  'runtime.fragment-timeout': (min: '1s', max: '600s'),
  'runtime.udp-associate-read-timeout': (min: '1s', max: '1h'),
  'runtime.terminal-stream-retention': (min: '1s', max: '1h'),
  'runtime.cancelled-setup-retention': (min: '1s', max: '1h'),
  'runtime.session-retry-base': (min: '100ms', max: '60s'),
  'runtime.session-retry-step': (min: '0s', max: '60s'),
  'runtime.session-retry-max': (min: '100ms', max: '1h'),
  'runtime.session-busy-retry-interval': (min: '1s', max: '1h'),
  'runtime.failover-cooldown': (min: '100ms', max: '120s'),
  'runtime.stats-interval': (min: '1s', max: '1h'),
  'resolver-policy.refresh': (min: '1m', max: '365d'),
  'startup.max-age': (min: '0s', max: '365d'),
};

/// Integer bounds of the StormDNS node block, keyed by profile path.
///
/// Derived from the schema instead of restated, so the resolver — which also
/// runs on the apply path, where `validate: false` skips
/// `StrictConfigSchemaValidator` — enforces exactly the bounds declared above.
/// `activation.*` is left out: those fields belong to every built-in node and
/// are resolved by the activation compiler, not by `StormDnsSettingsResolver`.
final stormDnsIntegerRanges = <String, ConfigValueRange>{
  for (final field in _stormDnsFields)
    if (field.type == ConfigValueType.integer &&
        !field.path.startsWith('stormdns.activation.') &&
        (field.range.minimum != null || field.range.maximum != null))
      field.path.substring('stormdns.'.length): field.range,
};

BuiltInProxyFieldSchema _duration(String path) => BuiltInProxyFieldSchema(
      path: 'stormdns.$path',
      type: ConfigValueType.string,
    );

BuiltInProxyFieldSchema _int(String path, {num? min, num? max}) =>
    BuiltInProxyFieldSchema(
      path: 'stormdns.$path',
      type: ConfigValueType.integer,
      range: ConfigValueRange(minimum: min, maximum: max),
    );

BuiltInProxyFieldSchema _object(String path) => BuiltInProxyFieldSchema(
      path: 'stormdns.$path',
      type: ConfigValueType.object,
    );

BuiltInProxyFieldSchema _forbidden(String path, String reason) =>
    BuiltInProxyFieldSchema(
      path: 'stormdns.$path',
      type: ConfigValueType.string,
      additionalTypes: const <ConfigValueType>{
        ConfigValueType.integer,
        ConfigValueType.boolean,
        ConfigValueType.object,
        ConfigValueType.list,
      },
      forbiddenReason: reason,
    );

final _stormDnsFields = <BuiltInProxyFieldSchema>[
  ..._activationFields('stormdns'),

  // Server-matched values. StormDNS has no negotiation, so none of the three
  // may have a default: a wrong guess silently produces a dead tunnel.
  const BuiltInProxyFieldSchema(
    path: 'stormdns.domains',
    type: ConfigValueType.list,
    required: true,
  ),
  const BuiltInProxyFieldSchema(
    path: 'stormdns.domains[]',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(
    path: 'stormdns.encryption',
    type: ConfigValueType.string,
    required: true,
    allowedValues: stormDnsEncryptionMethods.keys.toSet(),
  ),
  const BuiltInProxyFieldSchema(
    path: 'stormdns.encryption-key',
    type: ConfigValueType.string,
    required: true,
  ),

  const BuiltInProxyFieldSchema(
    path: 'stormdns.resolvers',
    type: ConfigValueType.list,
    defaultValue: ConfigDefaultValue.of(<String>['system']),
  ),
  const BuiltInProxyFieldSchema(
    path: 'stormdns.resolvers[]',
    type: ConfigValueType.string,
  ),

  _object('resolver-policy'),
  const BuiltInProxyFieldSchema(
    path: 'stormdns.resolver-policy.refresh',
    type: ConfigValueType.string,
    defaultValue: ConfigDefaultValue.of('24h'),
  ),
  BuiltInProxyFieldSchema(
    path: 'stormdns.resolver-policy.strategy',
    type: ConfigValueType.string,
    allowedValues: stormDnsResolverStrategies.keys.toSet(),
    defaultValue: const ConfigDefaultValue.of('least-loss'),
  ),
  const BuiltInProxyFieldSchema(
    path: 'stormdns.resolver-policy.auto-disable',
    type: ConfigValueType.boolean,
    defaultValue: ConfigDefaultValue.of(true),
  ),
  const BuiltInProxyFieldSchema(
    path: 'stormdns.resolver-policy.recheck',
    type: ConfigValueType.boolean,
    defaultValue: ConfigDefaultValue.of(true),
  ),

  BuiltInProxyFieldSchema(
    path: 'stormdns.preset',
    type: ConfigValueType.string,
    allowedValues: stormDnsPresets.keys.toSet(),
    defaultValue: const ConfigDefaultValue.of('messenger'),
  ),

  _object('duplication'),
  _int('duplication.upload', min: 1, max: 8),
  _int('duplication.download', min: 1, max: 8),
  _int('duplication.upload-setup', min: 1, max: 8),
  _int('duplication.download-setup', min: 1, max: 8),

  _object('compression'),
  BuiltInProxyFieldSchema(
    path: 'stormdns.compression.upload',
    type: ConfigValueType.string,
    allowedValues: stormDnsCompressionTypes.keys.toSet(),
  ),
  BuiltInProxyFieldSchema(
    path: 'stormdns.compression.download',
    type: ConfigValueType.string,
    allowedValues: stormDnsCompressionTypes.keys.toSet(),
  ),
  _int('compression.min-size', min: 100, max: 65535),

  _object('mtu'),
  _object('mtu.upload'),
  _int('mtu.upload.min', min: 1, max: 65535),
  _int('mtu.upload.max', min: 0, max: 65535),
  _object('mtu.download'),
  _int('mtu.download.min', min: 1, max: 65535),
  _int('mtu.download.max', min: 0, max: 65535),

  _object('arq'),
  _int('arq.window', min: 1, max: 6000),
  _duration('arq.initial-rto'),
  _duration('arq.max-rto'),
  _duration('arq.control-initial-rto'),
  _duration('arq.control-max-rto'),
  _int('arq.max-control-retries', min: 5, max: 5000),
  _duration('arq.inactivity-timeout'),
  _duration('arq.data-packet-ttl'),
  _duration('arq.control-packet-ttl'),
  _int('arq.max-data-retries', min: 60, max: 100000),
  _int('arq.nack-max-gap', min: 0, max: 1500),
  _duration('arq.nack-initial-delay'),
  _duration('arq.nack-repeat'),
  _duration('arq.terminal-drain-timeout'),
  _duration('arq.terminal-ack-wait-timeout'),

  _object('ping'),
  _duration('ping.aggressive-interval'),
  _duration('ping.lazy-interval'),
  _duration('ping.cooldown-interval'),
  _duration('ping.cold-interval'),
  _duration('ping.warm-threshold'),
  _duration('ping.cool-threshold'),
  _duration('ping.cold-threshold'),
  _duration('ping.watchdog-timeout'),

  _object('runtime'),
  _int('runtime.workers', min: 1, max: 64),
  _int('runtime.process-workers', min: 1, max: 64),
  _duration('runtime.packet-timeout'),
  _duration('runtime.idle-poll-interval'),
  _int('runtime.tx-channel-size', min: 64, max: 65536),
  _int('runtime.rx-channel-size', min: 64, max: 65536),
  _int('runtime.resolver-pool-size', min: 1, max: 1024),
  _int('runtime.stream-queue-capacity', min: 8, max: 65536),
  _int('runtime.orphan-queue-capacity', min: 4, max: 4096),
  _int('runtime.fragment-store-capacity', min: 16, max: 16384),
  _duration('runtime.fragment-timeout'),
  _duration('runtime.udp-associate-read-timeout'),
  _duration('runtime.terminal-stream-retention'),
  _duration('runtime.cancelled-setup-retention'),
  _duration('runtime.session-retry-base'),
  _duration('runtime.session-retry-step'),
  _int('runtime.session-retry-linear-after', min: 0, max: 1000),
  _duration('runtime.session-retry-max'),
  _duration('runtime.session-busy-retry-interval'),
  _int('runtime.max-packets-per-batch', min: 1, max: 64),
  _int('runtime.failover-resend-threshold', min: 1, max: 128),
  _duration('runtime.failover-cooldown'),
  _duration('runtime.stats-interval'),
  const BuiltInProxyFieldSchema(
    path: 'stormdns.runtime.base-encode',
    type: ConfigValueType.boolean,
    defaultValue: ConfigDefaultValue.of(false),
  ),

  _object('startup'),
  BuiltInProxyFieldSchema(
    path: 'stormdns.startup.mode',
    type: ConfigValueType.string,
    allowedValues: stormDnsStartupModes.keys.toSet(),
    defaultValue: const ConfigDefaultValue.of('cached'),
  ),
  const BuiltInProxyFieldSchema(
    path: 'stormdns.startup.max-age',
    type: ConfigValueType.string,
    defaultValue: ConfigDefaultValue.of('30d'),
  ),

  // Fields owned by FlClashM. The app always supplies SOCKS5 on localhost with
  // a dedicated port, an internal log directory, and the resolver file path.
  _forbidden('listen', 'the local listener is owned by FlClashM'),
  _forbidden('listen-ip', 'the local listener address is owned by FlClashM'),
  _forbidden('listen-port', 'the local listener port is owned by FlClashM'),
  _forbidden('server', 'the local listener is owned by FlClashM'),
  _forbidden('port', 'the local listener port is owned by FlClashM'),
  _forbidden('protocol', 'FlClashM always runs StormDNS as a SOCKS5 listener'),
  _forbidden(
    'socks5-auth',
    'SOCKS5 authentication on the local listener is owned by FlClashM',
  ),
  _forbidden(
    'socks5-user',
    'SOCKS5 authentication on the local listener is owned by FlClashM',
  ),
  _forbidden(
    'socks5-pass',
    'SOCKS5 authentication on the local listener is owned by FlClashM',
  ),
  _forbidden('local-dns', 'the local DNS listener is not supported'),
  _forbidden('local-dns-enabled', 'the local DNS listener is not supported'),
  _forbidden('local-dns-ip', 'the local DNS listener is not supported'),
  _forbidden('local-dns-port', 'the local DNS listener is not supported'),
  _forbidden('local-dns-cache', 'the local DNS listener is not supported'),
  _forbidden('log-dir', 'the runtime log directory is owned by FlClashM'),
  _forbidden('log-file-name', 'the runtime log file name is owned by FlClashM'),
  _forbidden('log', 'user-selected output paths are not supported'),
  _forbidden(
    'resolvers-file',
    'the resolver file is generated by FlClashM from `resolvers`',
  ),
  _forbidden(
    'config-version',
    'the generated config version is owned by FlClashM',
  ),
];
