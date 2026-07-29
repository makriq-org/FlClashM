import 'dart:convert';
import 'dart:io';

import 'package:flclashx/product/diagnostics/diagnostic_redactor.dart';
import 'package:flclashx/product/diagnostics/diagnostic_text_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final vectors = (jsonDecode(
    File(
      'lib/product/diagnostics/diagnostic_redaction_vectors.json',
    ).readAsStringSync(),
  ) as List)
      .cast<Map<String, Object?>>();

  for (final vector in vectors) {
    test('redacts shared vector ${vector['id']}', () {
      expect(
        DiagnosticRedactor.redact(vector['input']! as String),
        vector['expected'],
      );
    });
  }

  test('keeps useful non-secret lifecycle context', () {
    const input =
        'FlVpnService cold-start failed on Android API 35 with exit code 2';

    expect(DiagnosticRedactor.redact(input), input);
  });

  test('redacts a quoted secret cut by the UTF-8 boundary', () {
    final result = DiagnosticRedactor.redactBounded(
      'password="${'private phrase ' * 100}"',
      maxUtf8Bytes: 128,
    );

    expect(result, 'password=<redacted>$diagnosticTruncationMarker');
    expect(result, isNot(contains('private phrase')));
  });
}
