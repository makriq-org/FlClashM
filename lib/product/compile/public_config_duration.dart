/// Parses a duration from the public profile format.
///
/// Strings with explicit units are canonical. Integer seconds are accepted for
/// profiles written before the duration syntax was introduced.
Duration parsePublicConfigDuration(
  Object? value, {
  required String path,
  required Duration fallback,
  required Duration maximum,
  bool allowZero = false,
}) {
  if (value == null) return fallback;

  final Duration result;
  if (value is int) {
    result = Duration(seconds: value);
  } else if (value is String) {
    final match = RegExp(r'^(\d+)(ms|s|m|h|d)$').firstMatch(value);
    if (match == null) {
      throw FormatException(
        '`$path` must be a duration with an explicit unit, for example `5s`, '
        '`5m`, or `1d`.',
      );
    }
    final amount = int.parse(match.group(1)!);
    result = switch (match.group(2)) {
      'ms' => Duration(milliseconds: amount),
      's' => Duration(seconds: amount),
      'm' => Duration(minutes: amount),
      'h' => Duration(hours: amount),
      'd' => Duration(days: amount),
      _ => throw StateError('unreachable duration unit'),
    };
  } else {
    throw FormatException(
      '`$path` must be a duration string${allowZero ? '' : ' greater than zero'}.',
    );
  }

  if (result.isNegative || !allowZero && result == Duration.zero) {
    throw FormatException(
      '`$path` must be ${allowZero ? 'non-negative' : 'greater than zero'}.',
    );
  }
  if (result > maximum) {
    throw FormatException('`$path` exceeds the supported limit.');
  }
  return result;
}

String durationToGoString(Duration value) {
  if (value.inMicroseconds % Duration.microsecondsPerHour == 0) {
    return '${value.inHours}h';
  }
  if (value.inMicroseconds % Duration.microsecondsPerMinute == 0) {
    return '${value.inMinutes}m';
  }
  if (value.inMicroseconds % Duration.microsecondsPerSecond == 0) {
    return '${value.inSeconds}s';
  }
  if (value.inMicroseconds % Duration.microsecondsPerMillisecond == 0) {
    return '${value.inMilliseconds}ms';
  }
  return '${value.inMicroseconds}us';
}
