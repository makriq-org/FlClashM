import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flclashx/product/diagnostics/diagnostic_archive.dart';
import 'package:flclashx/product/diagnostics/diagnostic_file_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'builds a bounded readable ZIP and redacts every exported file',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'diagnostic-archive',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final logs = Directory('${temporary.path}/diagnostics')..createSync();
      File('${logs.path}/android-main.0.log').writeAsStringSync(
        'token=archive-secret\n'
        'support_url=https://example.com/support/private-token\n'
        'profile `Private profile title` failed\n',
      );
      File(
        '${logs.path}/flutter.0.log',
      ).writeAsStringSync('${'old-data\n' * 100}password=hunter2\n');

      const builder = DiagnosticArchiveBuilder(
        maxInputBytes: 1024,
        maxBytesPerFile: 256,
        maxArchiveBytes: 4096,
      );
      final bytes = await builder.build(
        directories: [logs],
        manifest: DiagnosticArchiveManifest(
          createdAt: DateTime.utc(2026, 7, 28),
          appVersion: '1.2.3',
          buildNumber: '42',
          appTag: 'v1.2.3',
          coreVersion: 'v1.19.28',
          androidApi: 35,
          androidAbis: const ['arm64-v8a'],
          androidFlushComplete: true,
          runtime: const {
            'vpnRunning': true,
            'coreInitialized': true,
            'logLevel': 'info',
            'uiAttached': true,
          },
        ),
      );

      expect(bytes.length, lessThanOrEqualTo(4096));
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(archive.files.map((file) => file.name), contains('manifest.json'));
      final allText = archive.files
          .where((file) => file.isFile)
          .map((file) => utf8.decode(file.content as List<int>))
          .join('\n');
      for (final secret in [
        'archive-secret',
        '/support/private-token',
        'Private profile title',
        'hunter2',
      ]) {
        expect(allText, isNot(contains(secret)), reason: secret);
      }
      expect(allText, contains('"profilesAndConfigsIncluded": false'));
      expect(allText, contains('"flushComplete": true'));
      expect(allText, contains('<older content omitted'));
    },
  );

  test('export remains readable while a source rotates', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'diagnostic-archive-rotation',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final logs = Directory('${temporary.path}/diagnostics')..createSync();
    final writer = DiagnosticFileWriter(
      directory: logs,
      source: 'android-remote',
      maxFileBytes: 128,
      maxFiles: 3,
    );
    const builder = DiagnosticArchiveBuilder(
      maxInputBytes: 4096,
      maxBytesPerFile: 512,
      maxArchiveBytes: 8192,
    );
    final manifest = DiagnosticArchiveManifest(
      createdAt: DateTime.utc(2026, 7, 28),
      appVersion: '1.2.3',
      buildNumber: '42',
      appTag: 'v1.2.3',
      coreVersion: 'v1.19.28',
      androidApi: 35,
      androidAbis: const ['arm64-v8a'],
      runtime: const {},
    );

    final writes = () async {
      for (var index = 0; index < 200; index++) {
        await writer.appendLines(['entry-$index-${'界' * 20}\n']);
      }
    }();
    final exports = Future.wait(
      List.generate(
        20,
        (_) => builder.build(directories: [logs], manifest: manifest),
      ),
    );

    final archives = await exports;
    await writes;
    for (final bytes in archives) {
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(
        archive.files.map((file) => file.name),
        contains('manifest.json'),
      );
    }
  });
}
