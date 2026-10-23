import 'dart:async';

import '../../common/app_localizations.dart';
import 'backend_client.dart';

/// Localized prefixes for failures reported by the backend.
class BackendErrorLabels {
  const BackendErrorLabels({
    required this.unavailable,
    required this.failed,
    required this.cancelled,
    required this.closed,
    required this.timeout,
  });

  factory BackendErrorLabels.current() => BackendErrorLabels(
    unavailable: appLocalizations.backendUnavailable,
    failed: appLocalizations.backendOperationFailed,
    cancelled: appLocalizations.backendOperationCancelled,
    closed: appLocalizations.backendClosed,
    timeout: appLocalizations.backendTimeout,
  );

  final String unavailable;
  final String failed;
  final String cancelled;
  final String closed;
  final String timeout;
}

// Generic English placeholders carry no information beyond the code itself.
const _genericCauses = {
  'operation failed',
  'operation cancelled',
  'operation canceled',
  'operation superseded',
  'operation closed',
  'failed',
  'cancelled',
  'canceled',
  'closed',
  'superseded',
};

/// User-facing text for [error]; empty when nothing should be shown.
///
/// A superseded operation is silent by default: a newer action replaced it.
/// Callers that treat an empty result as success pass [reportSuperseded] so a
/// command that never ran is reported as cancelled.
String formatBackendError(
  Object error,
  BackendErrorLabels labels, {
  bool reportSuperseded = false,
}) {
  if (error is BackendException) {
    if (error.isSuperseded) return reportSuperseded ? labels.cancelled : '';
    final prefix = switch (error.code) {
      BackendException.unavailable => labels.unavailable,
      BackendException.cancelled => labels.cancelled,
      BackendException.closed => labels.closed,
      _ => labels.failed,
    };
    // Transport causes (Binder, channel) are internal; they go to the log.
    if (error.code == BackendException.unavailable) return prefix;
    final cause = error.message.trim();
    if (cause.isEmpty || _genericCauses.contains(cause.toLowerCase())) {
      return prefix;
    }
    return '$prefix: $cause';
  }
  if (error is TimeoutException) return labels.timeout;
  if (error is StateError) return error.message;
  return '$error'.replaceFirst(RegExp(r'^Exception: '), '');
}

/// Whether [error] is an expected outcome rather than a failure to report.
bool isSilentBackendError(Object error) =>
    error is BackendException && error.isSuperseded;

String describeBackendError(Object error, {bool reportSuperseded = false}) =>
    formatBackendError(
      error,
      BackendErrorLabels.current(),
      reportSuperseded: reportSuperseded,
    );

/// A backend failure already translated for the user. UI wrappers that show
/// `error.toString()` display its text instead of the internal cause.
class DescribedBackendError implements Exception {
  const DescribedBackendError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Runs [action] for UI wrappers that show `error.toString()`, replacing
/// backend failures with their localized description.
Future<T> withDescribedBackendErrors<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on BackendException catch (error, stack) {
    Error.throwWithStackTrace(
      DescribedBackendError(
        describeBackendError(error, reportSuperseded: true),
      ),
      stack,
    );
  } on TimeoutException catch (error, stack) {
    Error.throwWithStackTrace(
      DescribedBackendError(describeBackendError(error)),
      stack,
    );
  }
}
