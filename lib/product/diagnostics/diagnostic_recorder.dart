import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'diagnostic_file_writer.dart';
import 'diagnostic_redactor.dart';

final class ProductDiagnosticRecorder {
  ProductDiagnosticRecorder({
    this.maxPendingEntries = 256,
    this.maxEntryCharacters = 16 * 1024,
  });

  final int maxPendingEntries;
  final int maxEntryCharacters;
  final ListQueue<String> _pending = ListQueue<String>();

  DiagnosticFileWriter? _writer;
  DiagnosticFileWriter? _criticalWriter;
  Future<void>? _activeDrain;
  int _droppedEntries = 0;
  bool _handlersInstalled = false;
  bool _disposed = false;

  Future<void> initialize(String homeDirectory) async {
    final directory = Directory(path.join(homeDirectory, 'diagnostics'));
    await directory.create(recursive: true);
    _writer = DiagnosticFileWriter(directory: directory, source: 'flutter');
    _criticalWriter = DiagnosticFileWriter(
      directory: directory,
      source: 'flutter-critical',
      maxFileBytes: 256 * 1024,
      maxFiles: 2,
    );
    _disposed = false;
    _scheduleDrain();
    await flush();
  }

  void installErrorHandlers() {
    if (_handlersInstalled) return;
    _handlersInstalled = true;

    final previousFlutterHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      recordCritical(
        'uncaught Flutter error: ${details.exceptionAsString()}',
        details.stack,
      );
      if (previousFlutterHandler != null) {
        previousFlutterHandler(details);
      } else {
        FlutterError.presentError(details);
      }
    };

    final dispatcher = PlatformDispatcher.instance;
    final previousPlatformHandler = dispatcher.onError;
    dispatcher.onError = (error, stackTrace) {
      recordCritical('uncaught Dart error: $error', stackTrace);
      return previousPlatformHandler?.call(error, stackTrace) ?? false;
    };
  }

  void record(String message) {
    if (_disposed) return;
    final line = _format(message);
    if (_pending.length >= maxPendingEntries) {
      _pending.removeFirst();
      _droppedEntries++;
    }
    _pending.addLast(line);
    _scheduleDrain();
  }

  void recordCritical(String message, [StackTrace? stackTrace]) {
    final text = stackTrace == null ? message : '$message\n$stackTrace';
    final line = _format(text);
    try {
      _criticalWriter?.appendLineSync(line);
    } catch (_) {
      // The platform crash handler must retain its original behaviour.
    }
  }

  Future<void> flush() async {
    _scheduleDrain();
    while (_activeDrain != null) {
      await _activeDrain;
      _scheduleDrain();
    }
  }

  Future<void> dispose() async {
    await flush();
    _disposed = true;
    _pending.clear();
  }

  String _format(String message) {
    final redacted = DiagnosticRedactor.redact(message);
    final bounded = redacted.length <= maxEntryCharacters
        ? redacted
        : '${redacted.substring(0, maxEntryCharacters)}…<truncated>';
    return '[${DateTime.now().toUtc().toIso8601String()}] $bounded\n';
  }

  void _scheduleDrain() {
    final writer = _writer;
    if (_disposed ||
        writer == null ||
        _pending.isEmpty ||
        _activeDrain != null) {
      return;
    }
    final drain = _drain(writer);
    _activeDrain = drain;
    unawaited(
      drain.whenComplete(() {
        if (identical(_activeDrain, drain)) _activeDrain = null;
        _scheduleDrain();
      }),
    );
  }

  Future<void> _drain(DiagnosticFileWriter writer) async {
    final lines = <String>[];
    var characters = 0;
    if (_droppedEntries > 0) {
      lines.add(
        _format('diagnostic queue dropped $_droppedEntries oldest entries'),
      );
      _droppedEntries = 0;
    }
    while (_pending.isNotEmpty && characters < 64 * 1024) {
      final line = _pending.removeFirst();
      lines.add(line);
      characters += line.length;
    }
    try {
      await writer.appendLines(lines);
    } catch (_) {
      // Local diagnostics must never destabilize the application.
    }
  }
}

final productDiagnosticRecorder = ProductDiagnosticRecorder();
