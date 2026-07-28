import 'dart:io';

import 'package:flclashx/product/diagnostics/diagnostic_recorder.dart';
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
}
