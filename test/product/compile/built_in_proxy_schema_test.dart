import 'package:flclashx/product/compile/built_in_proxy_schema.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flclashx/product/runtime/byedpi_release.dart';
import 'package:flclashx/product/runtime/naiveproxy_release.dart';
import 'package:flclashx/product/runtime/olcrtc_release.dart';
import 'package:flclashx/product/runtime/stormdns_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('schema registry is pinned to every bundled runtime release', () {
    const pinnedReleaseTags = <BuiltInProxyType, String>{
      BuiltInProxyType.naiveproxy: naiveProxyPinnedReleaseTag,
      BuiltInProxyType.byedpi: byedpiPinnedReleaseTag,
      BuiltInProxyType.olcrtc: olcRtcPinnedReleaseTag,
      BuiltInProxyType.stormdns: stormDnsPinnedReleaseTag,
    };

    // Every registered schema must be listed here, so a new node cannot ship
    // with a runtimeVersion that drifted away from its pinned binary.
    expect(pinnedReleaseTags.keys, containsAll(builtInProxySchemas.keys));
    for (final entry in pinnedReleaseTags.entries) {
      expect(
        builtInProxySchemas[entry.key]!.runtimeVersion,
        entry.value,
        reason: entry.key.label,
      );
    }
  });

  test('every schema field carries the complete contract metadata', () {
    for (final schema in builtInProxySchemas.values) {
      expect(schema.fields, isNotEmpty, reason: schema.type.label);
      for (final field in schema.fields) {
        expect(field.path, startsWith('${schema.type.label}.'));
        expect(field.type, isNotNull, reason: field.path);
        expect(field.required, isNotNull, reason: field.path);
        expect(field.modes, isNotNull, reason: field.path);
        expect(field.allowedValues, isNotNull, reason: field.path);
        expect(field.range, isNotNull, reason: field.path);
        expect(field.defaultValue, isNotNull, reason: field.path);
      }
    }
  });

  test('registry exposes recursive and mode-specific fields', () {
    final byedpi = builtInProxySchemas[BuiltInProxyType.byedpi]!;
    expect(
      byedpi.fields.singleWhere((field) => field.path == 'byedpi.args').modes,
      {'manual'},
    );
    expect(
      byedpi.fields
          .singleWhere((field) => field.path == 'byedpi.strategies[]')
          .modes,
      {'auto'},
    );

    final olcrtc = builtInProxySchemas[BuiltInProxyType.olcrtc]!;
    expect(
      olcrtc.fields.map((field) => field.path),
      containsAll(<String>{
        'olcrtc.profiles[].crypto.key',
        'olcrtc.activation',
        'olcrtc.activation.mode',
        'olcrtc.activation.wake',
        'olcrtc.activation.wake.urls',
        'olcrtc.activation.wake.urls[]',
        'olcrtc.activation.wake.interval',
        'olcrtc.activation.wake.failures',
        'olcrtc.activation.wake.retry-after',
        'olcrtc.activation.sleep',
        'olcrtc.activation.sleep.idle',
      }),
    );
    final activation = olcrtc.fields.singleWhere(
      (field) => field.path == 'olcrtc.activation',
    );
    expect(activation.type, ConfigValueType.string);
    expect(activation.additionalTypes, {ConfigValueType.object});
    expect(activation.allowedValues, {'auto', 'always'});
    expect(activation.defaultValue.value, 'auto');
    expect(
      olcrtc.fields
          .singleWhere(
            (field) => field.path == 'olcrtc.activation.wake.interval',
          )
          .defaultValue
          .value,
      30,
    );
    expect(
      olcrtc.fields
          .singleWhere(
            (field) => field.path == 'olcrtc.activation.sleep.idle',
          )
          .defaultValue
          .value,
      900,
    );
  });

  test('naiveproxy schema matches the user-facing compiler contract', () {
    final fields = {
      for (final field
          in builtInProxySchemas[BuiltInProxyType.naiveproxy]!.fields)
        field.path: field,
    };

    expect(
      fields.values.where((field) => field.required).map((field) => field.path),
      unorderedEquals(<String>{
        'naiveproxy.name',
        'naiveproxy.type',
        'naiveproxy.server',
        'naiveproxy.port',
        'naiveproxy.username',
        'naiveproxy.password',
      }),
    );
    expect(fields['naiveproxy.port']!.range.minimum, 1);
    expect(fields['naiveproxy.port']!.range.maximum, 65535);
    expect(fields['naiveproxy.transport']!.allowedValues, {'https', 'quic'});
    expect(fields['naiveproxy.transport']!.defaultValue.value, 'https');
    expect(fields['naiveproxy.insecure-concurrency']!.range.minimum, 1);
    expect(fields['naiveproxy.insecure-concurrency']!.range.maximum, 4);

    for (final entry in const <String, ConfigValueType>{
      'naiveproxy.transport': ConfigValueType.string,
      'naiveproxy.insecure-concurrency': ConfigValueType.integer,
      'naiveproxy.tunnel-timeout': ConfigValueType.integer,
      'naiveproxy.idle-timeout': ConfigValueType.integer,
      'naiveproxy.post-quantum': ConfigValueType.boolean,
      'naiveproxy.headers': ConfigValueType.object,
      'naiveproxy.host-resolver-rules': ConfigValueType.string,
    }.entries) {
      expect(fields[entry.key]!.type, entry.value, reason: entry.key);
      expect(fields[entry.key]!.required, isFalse, reason: entry.key);
      expect(fields[entry.key]!.forbiddenReason, isNull, reason: entry.key);
    }

    for (final path in const <String>{
      'naiveproxy.proxy',
      'naiveproxy.listen',
      'naiveproxy.log',
      'naiveproxy.log-net-log',
      'naiveproxy.ssl-key-log-file',
      'naiveproxy.no-post-quantum',
      'naiveproxy.resolver-range',
      'naiveproxy.extra-headers',
    }) {
      expect(fields[path]!.forbiddenReason, isNotEmpty, reason: path);
    }
  });

  test('registry exposes pinned effective OlcRTC defaults', () {
    final fields = {
      for (final field in builtInProxySchemas[BuiltInProxyType.olcrtc]!.fields)
        field.path: field,
    };
    expect(fields['olcrtc.failover.retry_delay']!.defaultValue.value, '2s');
    expect(fields['olcrtc.video.qr_size']!.defaultValue.value, 256);
    expect(fields['olcrtc.liveness.interval']!.defaultValue.value, '10s');
    expect(fields['olcrtc.liveness.timeout']!.defaultValue.value, '15s');
    expect(fields['olcrtc.liveness.failures']!.defaultValue.value, 4);
  });
}
