import 'package:flutter/foundation.dart';

import '../runtime/built_in_proxy_types.dart';
import '../runtime/byedpi_release.dart';
import '../runtime/naiveproxy_release.dart';
import '../runtime/olcrtc_release.dart';

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
  BuiltInProxyFieldSchema(
    path: 'common.udp',
    type: ConfigValueType.boolean,
  ),
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
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1, maximum: 60),
    defaultValue: ConfigDefaultValue.of(5),
  ),
  BuiltInProxyFieldSchema(
    path: 'common.connectivity-check.startup-timeout',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1, maximum: 300),
    defaultValue: ConfigDefaultValue.of(30),
  ),
  BuiltInProxyFieldSchema(
    path: 'common.connectivity-check.retry-interval',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1, maximum: 300),
    defaultValue: ConfigDefaultValue.of(1),
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
    range: ConfigValueRange(
      minimum: 0,
      maximum: 1,
      exclusiveMinimum: true,
    ),
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
        type: ConfigValueType.integer,
        range: ConfigValueRange(minimum: 1, maximum: 2147483647),
        defaultValue: ConfigDefaultValue.of(600),
      ),
      BuiltInProxyFieldSchema(
        path: 'naiveproxy.idle-timeout',
        type: ConfigValueType.integer,
        range: ConfigValueRange(minimum: 1, maximum: 2147483647),
        defaultValue: ConfigDefaultValue.of(300),
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
        path: 'byedpi.args',
        type: ConfigValueType.string,
        required: true,
        modes: <String>{'manual'},
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategies',
        type: ConfigValueType.list,
        modes: <String>{'auto'},
        defaultValue: ConfigDefaultValue.of(<String>[]),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategies[]',
        type: ConfigValueType.string,
        modes: <String>{'auto'},
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-list',
        type: ConfigValueType.string,
        modes: <String>{'auto'},
        allowedValues: <Object>{'byebyeedpi'},
        defaultValue: ConfigDefaultValue.of('byebyeedpi'),
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
        defaultValue:
            ConfigDefaultValue.of(<String>['https://youtube.com/generate_204']),
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
        path: 'byedpi.strategy-test.resolver',
        type: ConfigValueType.string,
        modes: <String>{'auto'},
        defaultValue: ConfigDefaultValue.of('https://1.1.1.1/dns-query'),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-test.timeout',
        type: ConfigValueType.integer,
        modes: <String>{'auto'},
        range: ConfigValueRange(minimum: 1, maximum: 60),
        defaultValue: ConfigDefaultValue.of(5),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-test.requests',
        type: ConfigValueType.integer,
        modes: <String>{'auto'},
        range: ConfigValueRange(minimum: 1, maximum: 32),
        defaultValue: ConfigDefaultValue.of(1),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-test.concurrency',
        type: ConfigValueType.integer,
        modes: <String>{'auto'},
        range: ConfigValueRange(minimum: 1, maximum: 16),
        defaultValue: ConfigDefaultValue.of(4),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.strategy-test.min-success-ratio',
        type: ConfigValueType.number,
        modes: <String>{'auto'},
        range: ConfigValueRange(
          minimum: 0,
          maximum: 1,
          exclusiveMinimum: true,
        ),
        defaultValue: ConfigDefaultValue.of(1.0),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.selection',
        type: ConfigValueType.object,
        modes: <String>{'auto'},
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.selection.concurrency',
        type: ConfigValueType.integer,
        modes: <String>{'auto'},
        range: ConfigValueRange(minimum: 1, maximum: 16),
        defaultValue: ConfigDefaultValue.of(4),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.selection.foreground-timeout',
        type: ConfigValueType.integer,
        modes: <String>{'auto'},
        range: ConfigValueRange(minimum: 1, maximum: 60),
        defaultValue: ConfigDefaultValue.of(15),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.selection.background',
        type: ConfigValueType.boolean,
        modes: <String>{'auto'},
        defaultValue: ConfigDefaultValue.of(true),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.fallback-args',
        type: ConfigValueType.string,
        modes: <String>{'auto'},
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.cache',
        type: ConfigValueType.object,
        modes: <String>{'auto'},
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.cache.ttl',
        type: ConfigValueType.integer,
        modes: <String>{'auto'},
        range: ConfigValueRange(minimum: 1, maximum: 31536000),
        defaultValue: ConfigDefaultValue.of(604800),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.cache.recheck-after',
        type: ConfigValueType.integer,
        modes: <String>{'auto'},
        range: ConfigValueRange(minimum: 1, maximum: 31536000),
        defaultValue: ConfigDefaultValue.of(86400),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.cache.retry-after',
        type: ConfigValueType.integer,
        modes: <String>{'auto'},
        range: ConfigValueRange(minimum: 1, maximum: 31536000),
        defaultValue: ConfigDefaultValue.of(300),
      ),
      BuiltInProxyFieldSchema(
        path: 'byedpi.cache.failure-threshold',
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
    fields: _forType('olcrtc', _olcRtcFields),
  ),
};

final _olcRtcFields = <BuiltInProxyFieldSchema>[
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.activation',
    type: ConfigValueType.string,
    additionalTypes: <ConfigValueType>{ConfigValueType.object},
    allowedValues: <Object>{'auto', 'always'},
    defaultValue: ConfigDefaultValue.of('auto'),
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.mode',
    type: ConfigValueType.string,
    allowedValues: <Object>{'auto', 'always'},
    defaultValue: ConfigDefaultValue.of('auto'),
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.wake',
    type: ConfigValueType.object,
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.wake.urls',
    type: ConfigValueType.list,
    defaultValue: ConfigDefaultValue.of(<String>[]),
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.wake.urls[]',
    type: ConfigValueType.string,
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.wake.interval',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1, maximum: 3600),
    defaultValue: ConfigDefaultValue.of(30),
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.wake.failures',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1, maximum: 10),
    defaultValue: ConfigDefaultValue.of(2),
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.wake.retry-after',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1, maximum: 86400),
    defaultValue: ConfigDefaultValue.of(300),
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.sleep',
    type: ConfigValueType.object,
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.activation.sleep.idle',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 0, maximum: 86400),
    defaultValue: ConfigDefaultValue.of(900),
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.mode',
    type: ConfigValueType.string,
    allowedValues: <Object>{'cnc'},
    defaultValue: ConfigDefaultValue.of('cnc'),
  ),
  const BuiltInProxyFieldSchema(
      path: 'olcrtc.auth', type: ConfigValueType.object),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.auth.provider',
    type: ConfigValueType.string,
    allowedValues: <Object>{'jitsi', 'telemost', 'wbstream', 'none'},
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.auth.token',
    type: ConfigValueType.string,
  ),
  const BuiltInProxyFieldSchema(
      path: 'olcrtc.room', type: ConfigValueType.object),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.room.id',
    type: ConfigValueType.string,
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.room.channel',
    type: ConfigValueType.string,
  ),
  const BuiltInProxyFieldSchema(
      path: 'olcrtc.crypto', type: ConfigValueType.object),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.crypto.key',
    type: ConfigValueType.string,
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.crypto.key_file',
    type: ConfigValueType.string,
    forbiddenReason: 'file-backed secrets are not supported',
  ),
  const BuiltInProxyFieldSchema(
      path: 'olcrtc.net', type: ConfigValueType.object),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.net.transport',
    type: ConfigValueType.string,
    allowedValues: <Object>{
      'datachannel',
      'videochannel',
      'seichannel',
      'vp8channel',
    },
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.net.dns',
    type: ConfigValueType.string,
  ),
  ..._olcRtcSocksFields,
  ..._olcRtcEngineFields,
  ..._olcRtcTransportFields,
  ..._olcRtcLifecycleFields,
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.profiles',
    type: ConfigValueType.list,
    defaultValue: ConfigDefaultValue.of(<Object>[]),
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.profiles[]',
    type: ConfigValueType.object,
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.profiles[].name',
    type: ConfigValueType.string,
  ),
  ..._olcRtcProfileFields,
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.failover',
    type: ConfigValueType.object,
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.failover.retry_delay',
    type: ConfigValueType.string,
    defaultValue: ConfigDefaultValue.of('2s'),
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.failover.max_cycles',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 0),
    defaultValue: ConfigDefaultValue.of(0),
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.debug',
    type: ConfigValueType.boolean,
    defaultValue: ConfigDefaultValue.of(false),
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.data',
    type: ConfigValueType.string,
    forbiddenReason: 'the runtime data directory is owned by FlClashM',
  ),
  const BuiltInProxyFieldSchema(
    path: 'olcrtc.gen',
    type: ConfigValueType.object,
    forbiddenReason: 'generation mode is not supported',
  ),
];

const _olcRtcSocksFields = <BuiltInProxyFieldSchema>[
  BuiltInProxyFieldSchema(path: 'olcrtc.socks', type: ConfigValueType.object),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.socks.host',
    type: ConfigValueType.string,
    forbiddenReason: 'the local listener address is owned by FlClashM',
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.socks.port',
    type: ConfigValueType.integer,
    forbiddenReason: 'the local listener port is owned by FlClashM',
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.socks.user',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.socks.pass',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.socks.proxy_addr',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.socks.proxy_port',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1, maximum: 65535),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.socks.proxy_user',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.socks.proxy_pass',
    type: ConfigValueType.string,
  ),
];

const _olcRtcEngineFields = <BuiltInProxyFieldSchema>[
  BuiltInProxyFieldSchema(path: 'olcrtc.engine', type: ConfigValueType.object),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.engine.name',
    type: ConfigValueType.string,
    allowedValues: <Object>{'livekit', 'goolom', 'jitsi'},
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.engine.url',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.engine.token',
    type: ConfigValueType.string,
  ),
];

const _olcRtcTransportFields = <BuiltInProxyFieldSchema>[
  BuiltInProxyFieldSchema(path: 'olcrtc.video', type: ConfigValueType.object),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.video.width',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1),
    defaultValue: ConfigDefaultValue.of(1920),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.video.height',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1),
    defaultValue: ConfigDefaultValue.of(1080),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.video.fps',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1),
    defaultValue: ConfigDefaultValue.of(30),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.video.bitrate',
    type: ConfigValueType.string,
    defaultValue: ConfigDefaultValue.of('2M'),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.video.hw',
    type: ConfigValueType.string,
    defaultValue: ConfigDefaultValue.of('none'),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.video.qr_size',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 0),
    defaultValue: ConfigDefaultValue.of(256),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.video.qr_recovery',
    type: ConfigValueType.string,
    allowedValues: <Object>{'low', 'medium', 'quartile', 'high', 'highest'},
    defaultValue: ConfigDefaultValue.of('low'),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.video.codec',
    type: ConfigValueType.string,
    allowedValues: <Object>{'qrcode', 'tile'},
    defaultValue: ConfigDefaultValue.of('qrcode'),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.video.tile_module',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 0),
    defaultValue: ConfigDefaultValue.of(4),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.video.tile_rs',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 0),
    defaultValue: ConfigDefaultValue.of(20),
  ),
  BuiltInProxyFieldSchema(path: 'olcrtc.vp8', type: ConfigValueType.object),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.vp8.fps',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1),
    defaultValue: ConfigDefaultValue.of(30),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.vp8.batch_size',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1),
    defaultValue: ConfigDefaultValue.of(64),
  ),
  BuiltInProxyFieldSchema(path: 'olcrtc.sei', type: ConfigValueType.object),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.sei.fps',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1),
    defaultValue: ConfigDefaultValue.of(30),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.sei.batch_size',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1),
    defaultValue: ConfigDefaultValue.of(64),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.sei.fragment_size',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1),
    defaultValue: ConfigDefaultValue.of(900),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.sei.ack_timeout_ms',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 1),
    defaultValue: ConfigDefaultValue.of(2000),
  ),
];

const _olcRtcLifecycleFields = <BuiltInProxyFieldSchema>[
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
    path: 'olcrtc.lifecycle.max_session_duration',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.traffic',
    type: ConfigValueType.object,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.traffic.max_payload_size',
    type: ConfigValueType.integer,
    range: ConfigValueRange(minimum: 0),
    defaultValue: ConfigDefaultValue.of(0),
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.traffic.min_delay',
    type: ConfigValueType.string,
  ),
  BuiltInProxyFieldSchema(
    path: 'olcrtc.traffic.max_delay',
    type: ConfigValueType.string,
  ),
];

final _olcRtcProfileFields = <BuiltInProxyFieldSchema>[
  for (final field in <BuiltInProxyFieldSchema>[
    ..._olcRtcSocksFields,
    ..._olcRtcEngineFields,
    ..._olcRtcTransportFields,
    ..._olcRtcLifecycleFields,
    const BuiltInProxyFieldSchema(
        path: 'olcrtc.auth', type: ConfigValueType.object),
    const BuiltInProxyFieldSchema(
      path: 'olcrtc.auth.provider',
      type: ConfigValueType.string,
      allowedValues: <Object>{'jitsi', 'telemost', 'wbstream', 'none'},
    ),
    const BuiltInProxyFieldSchema(
      path: 'olcrtc.auth.token',
      type: ConfigValueType.string,
    ),
    const BuiltInProxyFieldSchema(
        path: 'olcrtc.room', type: ConfigValueType.object),
    const BuiltInProxyFieldSchema(
      path: 'olcrtc.room.id',
      type: ConfigValueType.string,
    ),
    const BuiltInProxyFieldSchema(
      path: 'olcrtc.room.channel',
      type: ConfigValueType.string,
    ),
    const BuiltInProxyFieldSchema(
        path: 'olcrtc.crypto', type: ConfigValueType.object),
    const BuiltInProxyFieldSchema(
      path: 'olcrtc.crypto.key',
      type: ConfigValueType.string,
    ),
    const BuiltInProxyFieldSchema(
      path: 'olcrtc.crypto.key_file',
      type: ConfigValueType.string,
      forbiddenReason: 'file-backed secrets are not supported',
    ),
    const BuiltInProxyFieldSchema(
        path: 'olcrtc.net', type: ConfigValueType.object),
    const BuiltInProxyFieldSchema(
      path: 'olcrtc.net.transport',
      type: ConfigValueType.string,
      allowedValues: <Object>{
        'datachannel',
        'videochannel',
        'seichannel',
        'vp8channel',
      },
    ),
    const BuiltInProxyFieldSchema(
      path: 'olcrtc.net.dns',
      type: ConfigValueType.string,
    ),
  ])
    BuiltInProxyFieldSchema(
      path: field.path.replaceFirst('olcrtc.', 'olcrtc.profiles[].'),
      type: field.type,
      required: field.required,
      modes: field.modes,
      allowedValues: field.allowedValues,
      range: field.range,
      defaultValue: field.defaultValue,
      forbiddenReason: field.forbiddenReason,
    ),
];
