import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

import 'diagnostic_redactor.dart';

final class DiagnosticArchiveManifest {
  const DiagnosticArchiveManifest({
    required this.createdAt,
    required this.appVersion,
    required this.buildNumber,
    required this.appTag,
    required this.coreVersion,
    required this.androidApi,
    required this.androidAbis,
    required this.runtime,
    this.androidFlushComplete,
  });

  final DateTime createdAt;
  final String appVersion;
  final String buildNumber;
  final String appTag;
  final String coreVersion;
  final int? androidApi;
  final List<String> androidAbis;
  final Map<String, Object?> runtime;
  final bool? androidFlushComplete;

  Map<String, Object?> toJson({required List<Map<String, Object?>> files}) => {
        'schemaVersion': 1,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'application': {
          'version': appVersion,
          'build': buildNumber,
          'tag': appTag
        },
        'core': {'version': coreVersion},
        'platform': {
          'name': 'android',
          'api': androidApi,
          'abis': androidAbis,
          'flushComplete': androidFlushComplete,
        },
        'runtime': runtime,
        'files': files,
        'privacy': {
          'redactedBeforeWrite': true,
          'redactedAgainOnExport': true,
          'profilesAndConfigsIncluded': false,
        },
      };
}

final class DiagnosticArchiveBuilder {
  const DiagnosticArchiveBuilder({
    this.maxInputBytes = 6 * 1024 * 1024,
    this.maxBytesPerFile = 384 * 1024,
    this.maxArchiveBytes = 8 * 1024 * 1024,
  });

  final int maxInputBytes;
  final int maxBytesPerFile;
  final int maxArchiveBytes;

  Future<Uint8List> build({
    required Iterable<Directory> directories,
    required DiagnosticArchiveManifest manifest,
  }) async {
    final candidates = await _collectCandidates(directories);
    final archive = Archive();
    final fileEntries = <Map<String, Object?>>[];
    var remaining = maxInputBytes;
    var sequence = 0;

    for (final candidate in candidates) {
      if (remaining <= 0) break;
      final readLimit =
          maxBytesPerFile < remaining ? maxBytesPerFile : remaining;
      if (readLimit <= 0) continue;

      final tail = await _readTail(candidate.file, readLimit);
      if (tail == null) continue;
      final fileLength = tail.sourceLength;
      var bytes = tail.bytes;
      final truncated = fileLength > bytes.length;
      if (truncated) {
        final firstCompleteLine = bytes.indexOf(0x0a);
        bytes = firstCompleteLine < 0
            ? const <int>[]
            : bytes.sublist(firstCompleteLine + 1);
      }
      final raw = utf8.decode(bytes, allowMalformed: true);
      final redacted = DiagnosticRedactor.redact(raw);
      final prefix = truncated
          ? '<older content omitted; original-bytes=$fileLength>\n'
          : '';
      final safeBytes = utf8.encode('$prefix$redacted');
      final archiveName =
          'logs/${sequence.toString().padLeft(2, '0')}-${candidate.safeName}';
      archive.addFile(ArchiveFile(archiveName, safeBytes.length, safeBytes));
      fileEntries.add({
        'name': archiveName,
        'sourceBytes': fileLength,
        'exportedBytes': safeBytes.length,
        'truncated': truncated,
        'modifiedAt': candidate.modifiedAt.toUtc().toIso8601String(),
      });
      remaining -= bytes.length;
      sequence++;
    }

    final manifestBytes = utf8.encode(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(manifest.toJson(files: fileEntries)),
    );
    archive.addFile(
      ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
    );
    final encoded = ZipEncoder().encode(archive);
    if (encoded.length > maxArchiveBytes) {
      throw StateError(
        'Diagnostic archive exceeds the ${maxArchiveBytes}B safety limit.',
      );
    }
    return Uint8List.fromList(encoded);
  }

  Future<List<_DiagnosticCandidate>> _collectCandidates(
    Iterable<Directory> directories,
  ) async {
    final result = <_DiagnosticCandidate>[];
    final seenPaths = <String>{};
    for (final directory in directories) {
      // Export is initiated on the UI isolate; keep directory access async.
      // ignore: avoid_slow_async_io
      if (!await directory.exists()) continue;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.log')) continue;
        final canonical = entity.absolute.path;
        if (!seenPaths.add(canonical)) continue;
        final FileStat stat;
        try {
          // Export is initiated on the UI isolate; keep metadata access async.
          // ignore: avoid_slow_async_io
          stat = await entity.stat();
        } on FileSystemException {
          // A writer may rotate this path between listing and stat.
          continue;
        }
        result.add(
          _DiagnosticCandidate(
            file: entity,
            modifiedAt: stat.modified,
            sourceKey: _sourceKey(directory, entity),
            safeName: _safeFileName(
              '${path.basename(directory.path)}-${path.basename(entity.path)}',
            ),
          ),
        );
      }
    }
    result.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    final primary = <_DiagnosticCandidate>[];
    final rotations = <_DiagnosticCandidate>[];
    final seenSources = <String>{};
    for (final candidate in result) {
      if (seenSources.add(candidate.sourceKey)) {
        primary.add(candidate);
      } else {
        rotations.add(candidate);
      }
    }
    return [...primary, ...rotations];
  }

  Future<_DiagnosticTail?> _readTail(File file, int limit) async {
    RandomAccessFile? input;
    try {
      // Export is initiated on the UI isolate; keep file access async.
      // ignore: avoid_slow_async_io
      input = await file.open();
      final length = await input.length();
      final readLength = length < limit ? length : limit;
      if (length > readLength) {
        await input.setPosition(length - readLength);
      }
      return _DiagnosticTail(
        sourceLength: length,
        bytes: await input.read(readLength),
      );
    } on FileSystemException {
      // Rotation can remove the path before it is opened; another retained
      // generation still carries the source and export must remain usable.
      return null;
    } finally {
      try {
        await input?.close();
      } on FileSystemException {
        // A rotated descriptor can already be invalidated by the writer.
      }
    }
  }

  String _safeFileName(String value) {
    final safe = value.replaceAll(RegExp('[^a-zA-Z0-9._-]'), '_');
    return safe.isEmpty ? 'diagnostic.log' : safe;
  }

  String _sourceKey(Directory directory, File file) {
    final name = path.basename(file.path);
    final source = name.startsWith('FlClashM_')
        ? 'legacy-flutter'
        : name.replaceFirst(RegExp(r'\.\d+\.log$'), '');
    return '${path.basename(directory.path)}:$source';
  }
}

final class _DiagnosticCandidate {
  const _DiagnosticCandidate({
    required this.file,
    required this.modifiedAt,
    required this.sourceKey,
    required this.safeName,
  });

  final File file;
  final DateTime modifiedAt;
  final String sourceKey;
  final String safeName;
}

final class _DiagnosticTail {
  const _DiagnosticTail({
    required this.sourceLength,
    required this.bytes,
  });

  final int sourceLength;
  final List<int> bytes;
}
