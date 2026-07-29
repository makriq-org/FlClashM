import 'dart:io';

import 'package:flclashx/product/diagnostics/diagnostic_recorder.dart';
import 'package:flclashx/product/diagnostics/diagnostic_text_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'bounds the pre-initialization queue and records a drop marker',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'diagnostic-recorder',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final recorder = ProductDiagnosticRecorder(maxPendingEntries: 2)
        ..record('oldest-entry')
        ..record('newer-entry')
        ..record('newest-entry');
      await recorder.initialize(temporary.path);
      await recorder.flush();

      final output = File(
        '${temporary.path}/diagnostics/flutter.0.log',
      ).readAsStringSync();
      expect(output, isNot(contains('oldest-entry')));
      expect(output, contains('newer-entry'));
      expect(output, contains('newest-entry'));
      expect(output, contains('dropped 1 oldest entries'));
      await recorder.dispose();
    },
  );

  test('flush keeps the recorder active for developer data clearing', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'diagnostic-recorder-flush',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final recorder = ProductDiagnosticRecorder();
    await recorder.initialize(temporary.path);

    recorder.record('before-clear');
    await recorder.flush();
    recorder.record('after-clear');
    await recorder.flush();

    final output = File(
      '${temporary.path}/diagnostics/flutter.0.log',
    ).readAsStringSync();
    expect(output, contains('before-clear'));
    expect(output, contains('after-clear'));
    await recorder.dispose();
  });

  test('critical journal retains stack traces after redaction', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'diagnostic-recorder-critical',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final recorder = ProductDiagnosticRecorder();
    await recorder.initialize(temporary.path);

    recorder.recordCritical(
      'server failed auth=message-secret',
      StackTrace.fromString(
        'stack-marker\n--username stack-secret',
      ),
    );

    final output = File(
      '${temporary.path}/diagnostics/flutter-critical.0.log',
    ).readAsStringSync();
    expect(output, contains('server failed auth=<redacted>'));
    expect(output, contains('stack-marker'));
    expect(output, contains('--username <redacted>'));
    expect(output, isNot(contains('message-secret')));
    expect(output, isNot(contains('stack-secret')));
    await recorder.dispose();
  });

  test('bounds raw multibyte entries by UTF-8 bytes before persistence',
      () async {
    final temporary = await Directory.systemTemp.createTemp(
      'diagnostic-recorder-utf8',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final recorder = ProductDiagnosticRecorder(maxEntryBytes: 64);
    await recorder.initialize(temporary.path);

    recorder.record('界' * 100);
    await recorder.flush();

    final output = File(
      '${temporary.path}/diagnostics/flutter.0.log',
    ).readAsStringSync();
    final message = output.substring(output.indexOf('] ') + 2).trimRight();
    expect(diagnosticUtf8Length(message), lessThanOrEqualTo(64));
    expect(message, endsWith(diagnosticTruncationMarker));
    expect(message, isNot(contains('\uFFFD')));
    await recorder.dispose();
  });
}
