import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

final class DiagnosticFileWriter {
  DiagnosticFileWriter({
    required this.directory,
    required this.source,
    this.maxFileBytes = 512 * 1024,
    this.maxFiles = 4,
  })  : assert(
            maxFileBytes > 0, 'Diagnostic files must have a positive limit.'),
        assert(maxFiles > 0, 'At least one diagnostic file must be retained.');

  final Directory directory;
  final String source;
  final int maxFileBytes;
  final int maxFiles;

  File _file(int index) =>
      File(path.join(directory.path, '$source.$index.log'));

  Future<void> appendLines(Iterable<String> lines) async {
    await directory.create(recursive: true);
    RandomAccessFile? output;
    var length = await _currentLength();
    try {
      for (final line in lines) {
        final bytes = utf8.encode(line);
        if (length > 0 && length + bytes.length > maxFileBytes) {
          await output?.close();
          output = null;
          await _rotate();
          length = 0;
        }
        output ??= await _file(0).open(mode: FileMode.append);
        await output.writeFrom(bytes);
        length += bytes.length;
      }
      await output?.flush();
    } finally {
      await output?.close();
    }
  }

  void appendLineSync(String line) {
    directory.createSync(recursive: true);
    final bytes = utf8.encode(line);
    var length = _file(0).existsSync() ? _file(0).lengthSync() : 0;
    if (length > 0 && length + bytes.length > maxFileBytes) {
      _rotateSync();
      length = 0;
    }
    final output = _file(0).openSync(mode: FileMode.append);
    try {
      output.writeFromSync(bytes);
      output.flushSync();
    } finally {
      output.closeSync();
    }
  }

  Future<int> _currentLength() async {
    final current = _file(0);
    return await current.exists() ? current.length() : 0;
  }

  Future<void> _rotate() async {
    final oldest = _file(maxFiles - 1);
    if (await oldest.exists()) await oldest.delete();
    for (var index = maxFiles - 2; index >= 0; index--) {
      final from = _file(index);
      if (!await from.exists()) continue;
      final to = _file(index + 1);
      if (await to.exists()) await to.delete();
      await from.rename(to.path);
    }
  }

  void _rotateSync() {
    final oldest = _file(maxFiles - 1);
    if (oldest.existsSync()) oldest.deleteSync();
    for (var index = maxFiles - 2; index >= 0; index--) {
      final from = _file(index);
      if (!from.existsSync()) continue;
      final to = _file(index + 1);
      if (to.existsSync()) to.deleteSync();
      from.renameSync(to.path);
    }
  }
}
