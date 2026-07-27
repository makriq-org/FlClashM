import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../runtime/stormdns_release.dart';
import 'built_in_proxy_schema.dart';

/// Parses a StormDNS duration string.
///
/// Go's `time.ParseDuration` units plus `d` for days, which the profile
/// contract uses for `startup.max-age`.
Duration? parseStormDnsDuration(String value) {
  final text = value.trim();
  if (text.isEmpty) return null;
  final pattern = RegExp(r'(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m|h|d)');
  const factors = <String, double>{
    'ns': 1e-9,
    'us': 1e-6,
    'µs': 1e-6,
    'ms': 1e-3,
    's': 1,
    'm': 60,
    'h': 3600,
    'd': 86400,
  };
  final matches = pattern.allMatches(text).toList(growable: false);
  if (matches.isEmpty) return null;
  // Reject trailing or interleaved junk such as `10s junk` or `1x2s`.
  if (matches.map((match) => match.group(0)).join() != text) return null;
  var seconds = 0.0;
  for (final match in matches) {
    seconds += double.parse(match.group(1)!) * factors[match.group(2)]!;
  }
  return Duration(microseconds: (seconds * 1000000).round());
}

double _asSeconds(Duration value) => value.inMicroseconds / 1000000;

/// Effective StormDNS settings after `StormDNS defaults -> preset -> explicit`.
@immutable
class StormDnsSettings {
  const StormDnsSettings({
    required this.domains,
    required this.encryption,
    required this.encryptionKey,
    required this.uploadDuplication,
    required this.downloadDuplication,
    required this.uploadSetupDuplication,
    required this.downloadSetupDuplication,
    required this.uploadCompression,
    required this.downloadCompression,
    required this.compressionMinSize,
    required this.minUploadMtu,
    required this.maxUploadMtu,
    required this.minDownloadMtu,
    required this.maxDownloadMtu,
    required this.resolverStrategy,
    required this.resolverRefresh,
    required this.resolverAutoDisable,
    required this.resolverRecheck,
    required this.startupMode,
    required this.startupMaxAge,
    required this.arq,
    required this.ping,
    required this.runtime,
  });

  final List<String> domains;
  final String encryption;
  final String encryptionKey;
  final int uploadDuplication;
  final int downloadDuplication;
  final int uploadSetupDuplication;
  final int downloadSetupDuplication;
  final String uploadCompression;
  final String downloadCompression;
  final int? compressionMinSize;
  final int? minUploadMtu;
  final int? maxUploadMtu;
  final int? minDownloadMtu;
  final int? maxDownloadMtu;
  final String resolverStrategy;
  final Duration resolverRefresh;
  final bool resolverAutoDisable;
  final bool resolverRecheck;
  final String startupMode;
  final Duration startupMaxAge;
  final Map<String, Object> arq;
  final Map<String, Object> ping;
  final Map<String, Object> runtime;
}

/// Numeric StormDNS keys that carry a duration in the profile contract.
const _arqDurationKeys = <String, String>{
  'initial-rto': 'ARQ_INITIAL_RTO_SECONDS',
  'max-rto': 'ARQ_MAX_RTO_SECONDS',
  'control-initial-rto': 'ARQ_CONTROL_INITIAL_RTO_SECONDS',
  'control-max-rto': 'ARQ_CONTROL_MAX_RTO_SECONDS',
  'inactivity-timeout': 'ARQ_INACTIVITY_TIMEOUT_SECONDS',
  'data-packet-ttl': 'ARQ_DATA_PACKET_TTL_SECONDS',
  'control-packet-ttl': 'ARQ_CONTROL_PACKET_TTL_SECONDS',
  'nack-initial-delay': 'ARQ_DATA_NACK_INITIAL_DELAY_SECONDS',
  'nack-repeat': 'ARQ_DATA_NACK_REPEAT_SECONDS',
  'terminal-drain-timeout': 'ARQ_TERMINAL_DRAIN_TIMEOUT_SECONDS',
  'terminal-ack-wait-timeout': 'ARQ_TERMINAL_ACK_WAIT_TIMEOUT_SECONDS',
};

const _arqIntKeys = <String, String>{
  'window': 'ARQ_WINDOW_SIZE',
  'max-control-retries': 'ARQ_MAX_CONTROL_RETRIES',
  'max-data-retries': 'ARQ_MAX_DATA_RETRIES',
  'nack-max-gap': 'ARQ_DATA_NACK_MAX_GAP',
};

const _pingDurationKeys = <String, String>{
  'aggressive-interval': 'PING_AGGRESSIVE_INTERVAL_SECONDS',
  'lazy-interval': 'PING_LAZY_INTERVAL_SECONDS',
  'cooldown-interval': 'PING_COOLDOWN_INTERVAL_SECONDS',
  'cold-interval': 'PING_COLD_INTERVAL_SECONDS',
  'warm-threshold': 'PING_WARM_THRESHOLD_SECONDS',
  'cool-threshold': 'PING_COOL_THRESHOLD_SECONDS',
  'cold-threshold': 'PING_COLD_THRESHOLD_SECONDS',
  'watchdog-timeout': 'PING_WATCHDOG_TIMEOUT_SECONDS',
};

const _runtimeDurationKeys = <String, String>{
  'packet-timeout': 'TUNNEL_PACKET_TIMEOUT_SECONDS',
  'idle-poll-interval': 'DISPATCHER_IDLE_POLL_INTERVAL_SECONDS',
  'fragment-timeout': 'DNS_RESPONSE_FRAGMENT_TIMEOUT_SECONDS',
  'udp-associate-read-timeout': 'SOCKS_UDP_ASSOCIATE_READ_TIMEOUT_SECONDS',
  'terminal-stream-retention': 'CLIENT_TERMINAL_STREAM_RETENTION_SECONDS',
  'cancelled-setup-retention': 'CLIENT_CANCELLED_SETUP_RETENTION_SECONDS',
  'session-retry-base': 'SESSION_INIT_RETRY_BASE_SECONDS',
  'session-retry-step': 'SESSION_INIT_RETRY_STEP_SECONDS',
  'session-retry-max': 'SESSION_INIT_RETRY_MAX_SECONDS',
  'session-busy-retry-interval': 'SESSION_INIT_BUSY_RETRY_INTERVAL_SECONDS',
  'failover-cooldown': 'STREAM_RESOLVER_FAILOVER_COOLDOWN',
  'stats-interval': 'STATS_REPORT_INTERVAL_SECONDS',
};

const _runtimeIntKeys = <String, String>{
  'workers': 'RX_TX_WORKERS',
  'process-workers': 'TUNNEL_PROCESS_WORKERS',
  'tx-channel-size': 'TX_CHANNEL_SIZE',
  'rx-channel-size': 'RX_CHANNEL_SIZE',
  'resolver-pool-size': 'RESOLVER_UDP_CONNECTION_POOL_SIZE',
  'stream-queue-capacity': 'STREAM_QUEUE_INITIAL_CAPACITY',
  'orphan-queue-capacity': 'ORPHAN_QUEUE_INITIAL_CAPACITY',
  'fragment-store-capacity': 'DNS_RESPONSE_FRAGMENT_STORE_CAPACITY',
  'session-retry-linear-after': 'SESSION_INIT_RETRY_LINEAR_AFTER',
  'max-packets-per-batch': 'MAX_PACKETS_PER_BATCH',
  'failover-resend-threshold': 'STREAM_RESOLVER_FAILOVER_RESEND_THRESHOLD',
};

/// Resolves and validates the StormDNS block of one profile node.
///
/// Every bound that StormDNS would silently clamp is rejected here instead, so
/// a profile never runs with values different from what it declares.
class StormDnsSettingsResolver {
  const StormDnsSettingsResolver();

  StormDnsSettings resolve(Map<String, dynamic> config,
      {required String node}) {
    final presetName = _string(config['preset']) ?? 'messenger';
    final preset = stormDnsPresets[presetName];
    if (preset == null) {
      throw FormatException(
        '$node `preset` must be one of: ${stormDnsPresets.keys.join(', ')}.',
      );
    }

    final duplication = _map(config['duplication'], '$node `duplication`');
    final compression = _map(config['compression'], '$node `compression`');
    final mtu = _map(config['mtu'], '$node `mtu`');
    final mtuUpload = _map(mtu['upload'], '$node `mtu.upload`');
    final mtuDownload = _map(mtu['download'], '$node `mtu.download`');
    final policy = _map(config['resolver-policy'], '$node `resolver-policy`');
    final startup = _map(config['startup'], '$node `startup`');

    final uploadDuplication = _int(
      duplication['upload'],
      '$node `duplication.upload`',
      preset.duplication.upload,
    );
    final downloadDuplication = _int(
      duplication['download'],
      '$node `duplication.download`',
      preset.duplication.download,
    );
    final uploadSetupDuplication = _int(
      duplication['upload-setup'],
      '$node `duplication.upload-setup`',
      preset.duplication.uploadSetup,
    );
    final downloadSetupDuplication = _int(
      duplication['download-setup'],
      '$node `duplication.download-setup`',
      preset.duplication.downloadSetup,
    );

    // StormDNS raises setup duplication to the data duplication of the same
    // direction instead of reporting a conflict.
    if (uploadSetupDuplication < uploadDuplication) {
      throw FormatException(
        '$node `duplication.upload-setup` ($uploadSetupDuplication) must not '
        'be lower than `duplication.upload` ($uploadDuplication).',
      );
    }
    if (downloadSetupDuplication < downloadDuplication) {
      throw FormatException(
        '$node `duplication.download-setup` ($downloadSetupDuplication) must '
        'not be lower than `duplication.download` ($downloadDuplication).',
      );
    }

    final minUploadMtu = _optionalInt(
      mtuUpload['min'],
      '$node `mtu.upload.min`',
    );
    final maxUploadMtu = _optionalInt(
      mtuUpload['max'],
      '$node `mtu.upload.max`',
    );
    final minDownloadMtu = _optionalInt(
      mtuDownload['min'],
      '$node `mtu.download.min`',
    );
    final maxDownloadMtu = _optionalInt(
      mtuDownload['max'],
      '$node `mtu.download.max`',
    );
    _requireMtuOrder(
      min: minUploadMtu ?? 100,
      max: maxUploadMtu ?? 200,
      node: node,
      direction: 'upload',
    );
    _requireMtuOrder(
      min: minDownloadMtu ?? 1000,
      max: maxDownloadMtu ?? 4000,
      node: node,
      direction: 'download',
    );

    final startupModeName = _string(startup['mode']) ?? 'cached';
    if (startupModeName == 'ask') {
      throw FormatException(
        '$node `startup.mode: ask` is not supported: StormDNS would wait for '
        'terminal input that no Android runtime node can provide.',
      );
    }
    if (!stormDnsStartupModes.containsKey(startupModeName)) {
      throw FormatException(
        '$node `startup.mode` must be one of: '
        '${stormDnsStartupModes.keys.join(', ')}.',
      );
    }

    final arq = _resolveBlock(
      _map(config['arq'], '$node `arq`'),
      node: node,
      block: 'arq',
      durationKeys: _arqDurationKeys.keys.toSet(),
      intKeys: _arqIntKeys.keys.toSet(),
    );
    final ping = _resolveBlock(
      _map(config['ping'], '$node `ping`'),
      node: node,
      block: 'ping',
      durationKeys: _pingDurationKeys.keys.toSet(),
      intKeys: const <String>{},
    );
    final runtime = _resolveBlock(
      _map(config['runtime'], '$node `runtime`'),
      node: node,
      block: 'runtime',
      durationKeys: _runtimeDurationKeys.keys.toSet(),
      intKeys: _runtimeIntKeys.keys.toSet(),
      boolKeys: const <String>{'base-encode'},
    );

    _requireOrder(arq, node, 'arq', 'initial-rto', 'max-rto', 0.6, 3.0);
    _requireOrder(
      arq,
      node,
      'arq',
      'control-initial-rto',
      'control-max-rto',
      0.5,
      2.0,
    );
    _requireNackGap(arq, node);
    _requireOrder(
      ping,
      node,
      'ping',
      'aggressive-interval',
      'lazy-interval',
      0.2,
      0.75,
    );
    _requireOrder(
      ping,
      node,
      'ping',
      'lazy-interval',
      'cooldown-interval',
      0.75,
      2.0,
    );
    _requireOrder(
      ping,
      node,
      'ping',
      'cooldown-interval',
      'cold-interval',
      2.0,
      15.0,
    );
    _requireOrder(
      ping,
      node,
      'ping',
      'warm-threshold',
      'cool-threshold',
      5.0,
      15.0,
    );
    _requireOrder(
      ping,
      node,
      'ping',
      'cool-threshold',
      'cold-threshold',
      15.0,
      30.0,
    );
    _requireOrder(
      runtime,
      node,
      'runtime',
      'session-retry-base',
      'session-retry-max',
      1.0,
      60.0,
    );
    _requireWorkerOrder(runtime, node);
    final startupMaxAge = _requireDuration(
      startup['max-age'],
      node: node,
      path: 'startup.max-age',
      fallback: const Duration(days: 30),
    )!;
    if (startupMaxAge.inMicroseconds % const Duration(days: 1).inMicroseconds !=
        0) {
      throw FormatException(
        '$node `startup.max-age` must be a whole number of days because '
        'StormDNS stores this setting as an integer day count.',
      );
    }

    return StormDnsSettings(
      domains: _requireDomains(config['domains'], node),
      encryption: _requireEncryption(config['encryption'], node),
      encryptionKey: _requireEncryptionKey(config['encryption-key'], node),
      uploadDuplication: uploadDuplication,
      downloadDuplication: downloadDuplication,
      uploadSetupDuplication: uploadSetupDuplication,
      downloadSetupDuplication: downloadSetupDuplication,
      uploadCompression: _requireChoice(
        compression['upload'],
        fallback: preset.compression,
        allowed: stormDnsCompressionTypes,
        node: node,
        path: 'compression.upload',
      ),
      downloadCompression: _requireChoice(
        compression['download'],
        fallback: preset.compression,
        allowed: stormDnsCompressionTypes,
        node: node,
        path: 'compression.download',
      ),
      compressionMinSize: _optionalInt(
        compression['min-size'],
        '$node `compression.min-size`',
      ),
      minUploadMtu: minUploadMtu,
      maxUploadMtu: maxUploadMtu,
      minDownloadMtu: minDownloadMtu,
      maxDownloadMtu: maxDownloadMtu,
      resolverStrategy: _requireChoice(
        policy['strategy'],
        fallback: 'least-loss',
        allowed: stormDnsResolverStrategies,
        node: node,
        path: 'resolver-policy.strategy',
      ),
      resolverRefresh: _requireDuration(
        policy['refresh'],
        node: node,
        path: 'resolver-policy.refresh',
        fallback: const Duration(hours: 24),
      )!,
      resolverAutoDisable: _bool(policy['auto-disable']) ?? true,
      resolverRecheck: _bool(policy['recheck']) ?? true,
      startupMode: startupModeName,
      startupMaxAge: startupMaxAge,
      arq: arq,
      ping: ping,
      runtime: runtime,
    );
  }

  Map<String, Object> _resolveBlock(
    Map<String, dynamic> raw, {
    required String node,
    required String block,
    required Set<String> durationKeys,
    required Set<String> intKeys,
    Set<String> boolKeys = const <String>{},
  }) {
    final result = <String, Object>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      if (durationKeys.contains(key)) {
        result[key] = _requireDuration(
          entry.value,
          node: node,
          path: '$block.$key',
          fallback: null,
        )!;
        continue;
      }
      if (intKeys.contains(key)) {
        result[key] = _int(entry.value, '$node `$block.$key`', 0);
        continue;
      }
      if (boolKeys.contains(key)) {
        final value = _bool(entry.value);
        if (value == null) {
          throw FormatException('$node `$block.$key` must be a boolean.');
        }
        result[key] = value;
        continue;
      }
      throw FormatException('$node `$block.$key` is not a supported field.');
    }
    return result;
  }

  Duration? _requireDuration(
    Object? value, {
    required String node,
    required String path,
    required Duration? fallback,
  }) {
    if (value == null) return fallback;
    if (value is! String) {
      throw FormatException(
        '$node `$path` must be a duration string such as `30s` or `24h`.',
      );
    }
    final parsed = parseStormDnsDuration(value);
    if (parsed == null) {
      throw FormatException(
        '$node `$path` has invalid duration `$value`; use units such as '
        '`ms`, `s`, `m`, `h`, or `d`.',
      );
    }
    final bounds = stormDnsDurationRanges[path];
    if (bounds != null) {
      final minimum = parseStormDnsDuration(bounds.min)!;
      final maximum = parseStormDnsDuration(bounds.max)!;
      if (parsed < minimum || parsed > maximum) {
        throw FormatException(
          '$node `$path` must be between ${bounds.min} and ${bounds.max}; '
          'StormDNS would silently clamp `$value`.',
        );
      }
    }
    return parsed;
  }

  void _requireOrder(
    Map<String, Object> block,
    String node,
    String blockName,
    String lowerKey,
    String upperKey,
    double lowerFallbackSeconds,
    double upperFallbackSeconds,
  ) {
    final lower = block[lowerKey] as Duration?;
    final upper = block[upperKey] as Duration?;
    final lowerSeconds =
        lower == null ? lowerFallbackSeconds : _asSeconds(lower);
    final upperSeconds =
        upper == null ? upperFallbackSeconds : _asSeconds(upper);
    if (upperSeconds < lowerSeconds) {
      throw FormatException(
        '$node `$blockName.$upperKey` must not be lower than '
        '`$blockName.$lowerKey`; StormDNS would silently raise it.',
      );
    }
  }

  void _requireNackGap(Map<String, Object> arq, String node) {
    final gap = arq['nack-max-gap'] as int?;
    if (gap == null) return;
    final window = (arq['window'] as int?) ?? 1000;
    final maximum = window ~/ 4;
    if (gap > maximum) {
      throw FormatException(
        '$node `arq.nack-max-gap` ($gap) must not exceed a quarter of '
        '`arq.window` ($window), which is $maximum.',
      );
    }
  }

  void _requireWorkerOrder(Map<String, Object> runtime, String node) {
    final workers = (runtime['workers'] as int?) ?? 4;
    final processWorkers = (runtime['process-workers'] as int?) ?? 4;
    if (processWorkers < workers) {
      throw FormatException(
        '$node `runtime.process-workers` ($processWorkers) must not be lower '
        'than `runtime.workers` ($workers); StormDNS would silently raise it.',
      );
    }
  }

  void _requireMtuOrder({
    required int min,
    required int max,
    required String node,
    required String direction,
  }) {
    if (max > 0 && min > max) {
      throw FormatException(
        '$node `mtu.$direction.max` ($max) must not be lower than '
        '`mtu.$direction.min` ($min).',
      );
    }
  }

  List<String> _requireDomains(Object? value, String node) {
    if (value is! List || value.isEmpty) {
      throw FormatException(
        '$node requires a non-empty `domains` list matching the server.',
      );
    }
    final unique = <String>{};
    for (final item in value) {
      final domain = _string(item)?.toLowerCase();
      final normalized = domain?.replaceAll(RegExp(r'\.+$'), '');
      if (normalized == null || normalized.isEmpty) {
        throw FormatException('$node `domains` must contain non-empty names.');
      }
      if (!RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?'
              r'(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$')
          .hasMatch(normalized)) {
        throw FormatException(
          '$node `domains` entry `$normalized` is not a domain name.',
        );
      }
      unique.add(normalized);
    }
    // StormDNS sorts longest-first and de-duplicates; matching that here keeps
    // the generated config stable across profile edits.
    final domains = unique.toList()
      ..sort((left, right) => left.length == right.length
          ? left.compareTo(right)
          : right.length - left.length);
    return List<String>.unmodifiable(domains);
  }

  String _requireEncryption(Object? value, String node) {
    final method = _string(value);
    if (method == null || !stormDnsEncryptionMethods.containsKey(method)) {
      throw FormatException(
        '$node requires `encryption` to be one of: '
        '${stormDnsEncryptionMethods.keys.join(', ')}.',
      );
    }
    return method;
  }

  /// Rejects a value that has no StormDNS counterpart.
  ///
  /// The apply path compiles with `validate: false`, so the schema pass that
  /// also knows these value sets is skipped. Without this check an unknown name
  /// reached the TOML writer, which had no table entry for it.
  String _requireChoice(
    Object? value, {
    required String fallback,
    required Map<String, Object?> allowed,
    required String node,
    required String path,
  }) {
    final name = _string(value) ?? fallback;
    if (!allowed.containsKey(name)) {
      throw FormatException(
        '$node `$path` must be one of: ${allowed.keys.join(', ')}.',
      );
    }
    return name;
  }

  String _requireEncryptionKey(Object? value, String node) {
    if (value is! String || value.trim().isEmpty) {
      throw FormatException(
        '$node requires a non-empty `encryption-key` matching the server.',
      );
    }
    return value.trim();
  }

  Map<String, dynamic> _map(Object? value, String label) {
    if (value == null) return <String, dynamic>{};
    if (value is! Map) throw FormatException('$label must be a map.');
    return value.map((key, item) => MapEntry(key.toString(), item));
  }

  int _int(Object? value, String label, int fallback) {
    if (value == null) return fallback;
    if (value is! int) throw FormatException('$label must be an integer.');
    return value;
  }

  int? _optionalInt(Object? value, String label) {
    if (value == null) return null;
    if (value is! int) throw FormatException('$label must be an integer.');
    return value;
  }

  bool? _bool(Object? value) => value is bool ? value : null;

  String? _string(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// Renders the StormDNS client TOML for one node.
///
/// Everything the app owns — listener, SOCKS auth, local DNS, log directory,
/// resolver file — is written here and cannot be supplied by the profile.
String buildStormDnsToml({
  required StormDnsSettings settings,
  required String listenHost,
  required int listenPort,
  required String logDirectory,
}) {
  // Every enum-like value is looked up through `_requireCode`: an unmapped name
  // used to be interpolated as the literal `null`, producing a TOML file
  // StormDNS would read with its own defaults instead of what the profile
  // declared. `StormDnsSettingsResolver` rejects such values first; this is the
  // backstop for any future caller that builds settings by hand.
  final startup = _requireCode(
    stormDnsStartupModes,
    settings.startupMode,
    'startup.mode',
  );
  final encryptionMethod = _requireCode(
    stormDnsEncryptionMethods,
    settings.encryption,
    'encryption',
  );
  final strategy = _requireCode(
    stormDnsResolverStrategies,
    settings.resolverStrategy,
    'resolver-policy.strategy',
  );
  final uploadCompression = _requireCode(
    stormDnsCompressionTypes,
    settings.uploadCompression,
    'compression.upload',
  );
  final downloadCompression = _requireCode(
    stormDnsCompressionTypes,
    settings.downloadCompression,
    'compression.download',
  );
  final downloadSetup = settings.downloadSetupDuplication;
  final lines = <String>[
    '# Generated by FlClashM. Do not edit: the profile is the source of truth.',
    '',
    'PROTOCOL_TYPE = "SOCKS5"',
    'LISTEN_IP = ${_tomlString(listenHost)}',
    'LISTEN_PORT = $listenPort',
    'SOCKS5_AUTH = false',
    '',
    'DOMAINS = [${settings.domains.map(_tomlString).join(', ')}]',
    'DATA_ENCRYPTION_METHOD = $encryptionMethod',
    'ENCRYPTION_KEY = ${_tomlString(settings.encryptionKey)}',
    '',
    '# The app never exposes a local DNS listener.',
    'LOCAL_DNS_ENABLED = false',
    '',
    'RESOLVER_BALANCING_STRATEGY = $strategy',
    'RECHECK_INACTIVE_SERVERS_ENABLED = ${settings.resolverRecheck}',
    'AUTO_DISABLE_TIMEOUT_SERVERS = ${settings.resolverAutoDisable}',
    '',
    'UPLOAD_PACKET_DUPLICATION_COUNT = ${settings.uploadDuplication}',
    'DOWNLOAD_PACKET_DUPLICATION_COUNT = ${settings.downloadDuplication}',
    'UPLOAD_SETUP_PACKET_DUPLICATION_COUNT = ${settings.uploadSetupDuplication}',
    'DOWNLOAD_SETUP_PACKET_DUPLICATION_COUNT = $downloadSetup',
    '',
    'UPLOAD_COMPRESSION_TYPE = $uploadCompression',
    'DOWNLOAD_COMPRESSION_TYPE = $downloadCompression',
    if (settings.compressionMinSize case final minSize?)
      'COMPRESSION_MIN_SIZE = $minSize',
    '',
    if (settings.minUploadMtu case final value?) 'MIN_UPLOAD_MTU = $value',
    if (settings.maxUploadMtu case final value?) 'MAX_UPLOAD_MTU = $value',
    if (settings.minDownloadMtu case final value?) 'MIN_DOWNLOAD_MTU = $value',
    if (settings.maxDownloadMtu case final value?) 'MAX_DOWNLOAD_MTU = $value',
    '',
    '# The resolver cache log is always on; the app owns its directory.',
    'LOG_TO_FILE = true',
    'LOG_DIR = ${_tomlString(logDirectory)}',
    'STARTUP_MODE = ${_tomlString(startup.mode)}',
    'LOG_BASED_MTU_VERIFY = ${startup.verifyMtu}',
    'LOG_SCAN_MAX_DAYS = ${settings.startupMaxAge.inDays}',
    for (final entry
        in _blockLines(settings.arq, _arqIntKeys, _arqDurationKeys))
      entry,
    for (final entry in _blockLines(
        settings.ping, const <String, String>{}, _pingDurationKeys))
      entry,
    for (final entry
        in _blockLines(settings.runtime, _runtimeIntKeys, _runtimeDurationKeys))
      entry,
    if (settings.runtime['base-encode'] case final bool value)
      'BASE_ENCODE_DATA = $value',
    '',
  ];
  return '${lines.join('\n')}\n';
}

/// Looks up the StormDNS counterpart of an enum-like setting.
///
/// Throws instead of returning `null`, so a value that never passed validation
/// cannot be written into the generated TOML.
T _requireCode<T extends Object>(
  Map<String, T> table,
  String name,
  String field,
) {
  final code = table[name];
  if (code == null) {
    throw FormatException(
      '`$field` value `$name` has no StormDNS counterpart; expected one of: '
      '${table.keys.join(', ')}.',
    );
  }
  return code;
}

List<String> _blockLines(
  Map<String, Object> block,
  Map<String, String> intKeys,
  Map<String, String> durationKeys,
) {
  final lines = <String>[];
  for (final entry in block.entries) {
    final value = entry.value;
    if (value is Duration && durationKeys.containsKey(entry.key)) {
      lines.add('${durationKeys[entry.key]} = ${_tomlFloat(value)}');
      continue;
    }
    if (value is int && intKeys.containsKey(entry.key)) {
      lines.add('${intKeys[entry.key]} = $value');
    }
  }
  lines.sort();
  return lines.isEmpty ? lines : ['', ...lines];
}

String _tomlFloat(Duration value) {
  final seconds = _asSeconds(value);
  final text = seconds.toStringAsFixed(6);
  final trimmed = text.replaceFirst(RegExp(r'0+$'), '');
  return trimmed.endsWith('.') ? '${trimmed}0' : trimmed;
}

String _tomlString(String value) => json.encode(value);

/// Binds the working cache to the resolver list, domains, and runtime build.
///
/// A cache produced for a different resolver set or a different StormDNS build
/// is not reusable, so it lives in its own directory and only becomes the
/// active one after the runtime plan commits.
String stormDnsCacheFingerprint({
  required List<String> resolverLines,
  required List<String> domains,
}) {
  final source = json.encode(<String, dynamic>{
    'runtime': stormDnsPinnedReleaseTag,
    'domains': domains,
    'resolvers': resolverLines,
  });
  return sha256.convert(utf8.encode(source)).toString().substring(0, 16);
}
