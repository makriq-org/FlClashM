import 'dart:io';

import 'package:flclashx/product/diagnostics/diagnostic_file_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rotates files and enforces the retained file count', () async {
    final temporary = await Directory.systemTemp.createTemp('diagnostic-store');
    addTearDown(() => temporary.delete(recursive: true));
    final writer = DiagnosticFileWriter(
      directory: temporary,
      source: 'flutter',
      maxFileBytes: 80,
      maxFiles: 3,
    );

    for (var index = 0; index < 12; index++) {
      await writer.appendLines(['entry-$index-${'x' * 28}\n']);
    }

    final files = temporary
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.log'))
        .toList();
    expect(files, hasLength(3));
    expect(files.every((file) => file.lengthSync() <= 80), isTrue);
    expect(
      files.map((file) => file.readAsStringSync()).join(),
      contains('entry-11'),
    );
  });
}
