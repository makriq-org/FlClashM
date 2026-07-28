import 'dart:async';

import 'package:flclashx/product/diagnostics/diagnostic_recorder.dart';

/// Stable base facade for the fork-owned diagnostic recorder.
///
/// The previous implementation kept an unbounded in-memory queue and wrote
/// unredacted values. Keeping this facade avoids spreading product diagnostics
/// through upstream call sites while the recorder owns limits, rotation and
/// security policy.
class FileLogger {
  factory FileLogger() {
    _instance ??= FileLogger._internal();
    return _instance!;
  }

  FileLogger._internal();
  static FileLogger? _instance;

  void log(String message) => productDiagnosticRecorder.record(message);

  void flushPendingLogs() {
    unawaited(productDiagnosticRecorder.flush());
  }

  Future<void> flush() => productDiagnosticRecorder.flush();

  Future<void> dispose() => productDiagnosticRecorder.dispose();
}

final fileLogger = FileLogger();
