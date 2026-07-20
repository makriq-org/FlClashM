import 'package:flclashx/product/compile/built_in_proxy_schema.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flclashx/product/runtime/byedpi_release.dart';
import 'package:flclashx/product/runtime/naiveproxy_release.dart';
import 'package:flclashx/product/runtime/olcrtc_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('schema registry is pinned to every bundled runtime release', () {
    expect(
      builtInProxySchemas[BuiltInProxyType.naiveproxy]!.runtimeVersion,
      naiveProxyPinnedReleaseTag,
    );
    expect(
      builtInProxySchemas[BuiltInProxyType.byedpi]!.runtimeVersion,
      byedpiPinnedReleaseTag,
    );
    expect(
      builtInProxySchemas[BuiltInProxyType.olcrtc]!.runtimeVersion,
      olcRtcPinnedReleaseTag,
    );
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
      contains('olcrtc.profiles[].crypto.key'),
    );
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
