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
  });

  final DateTime createdAt;
  final String appVersion;
  final String buildNumber;
  final String appTag;
  final String coreVersion;
  final int? androidApi;
  final List<String> androidAbis;
  final Map<String, Object?> runtime;

  Map<String, Object?> toJson({required List<Map<String, Object?>> files}) => {
        'schemaVersion': 1,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'application': {
          'version': appVersion,
          'build': buildNumber,
          'tag': appTag
        },
        'core': {'version': coreVersion},
        'platform': {'name': 'android', 'api': androidApi, 'abis': androidAbis},
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
      final fileLength = await candidate.file.length();
      final readLimit = [
        fileLength,
        maxBytesPerFile,
        remaining,
      ].reduce((a, b) => a < b ? a : b);
      if (readLimit <= 0) continue;

      var bytes = await _readTail(candidate.file, readLimit);
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
      if (!await directory.exists()) continue;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.log')) continue;
        final canonical = entity.absolute.path;
        if (!seenPaths.add(canonical)) continue;
        final stat = await entity.stat();
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

  Future<List<int>> _readTail(File file, int limit) async {
    final length = await file.length();
    final input = await file.open();
    try {
      if (length > limit) await input.setPosition(length - limit);
      return await input.read(limit);
    } finally {
      await input.close();
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
