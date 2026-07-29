import 'diagnostic_text_limiter.dart';

final class DiagnosticRedactor {
  const DiagnosticRedactor._();

  static const replacement = '<redacted>';
  static const urlReplacement = '<redacted-url>';

  static final RegExp _url = RegExp(
    r'''(?:https?|socks5?|ss|trojan|vmess|vless)://[^\s<>"']+''',
    caseSensitive: false,
  );
  static final RegExp _authorization = RegExp(
    r'\b(?:bearer|basic)\s+[a-z0-9._~+/=-]+',
    caseSensitive: false,
  );
  static final RegExp _sensitivePair = RegExp(
    r'''(["']?(?:password|passwd|pwd|token|access[_-]?token|refresh[_-]?token|secret|auth|authorization|proxy[_-]?authorization|api[_-]?key|apikey|subscription(?:[_-]?url)?|support[_-]?url|username|profile[_-]?(?:name|title)|currentProfileName|node[_-]?name)["']?\s*[:=]\s*)(?:"[^"]*(?:"|$)|'[^']*(?:'|$)|[^\s,;}\]]+)''',
    caseSensitive: false,
  );
  static final RegExp _sensitiveArgument = RegExp(
    r'''(--(?:password|passwd|token|secret|auth|authorization|api[_-]?key|subscription[_-]?url|support[_-]?url|username)(?:=|\s+))(?:"[^"]*(?:"|$)|'[^']*(?:'|$)|[^\s]+)''',
    caseSensitive: false,
  );
  static final RegExp _profileLabel = RegExp(
    r'''(\b(?:profile|node)\s+(?:name\s+)?)(?:`[^`]*(?:`|$)|"[^"]*(?:"|$)|'[^']*(?:'|$))''',
    caseSensitive: false,
  );
  static final RegExp _rawPayload = RegExp(
    r'''(\b(?:raw(?:[\s_-]?(?:config|data|payload))?|ipc[\s_-]?payload|quickstart[\s_-]?params|profile[\s_-]?yaml|subscription[\s_-]?content)\s*[:=]\s*)(?:\{.*|\[.*|.+)$''',
    caseSensitive: false,
    dotAll: true,
  );

  static String redact(String value) {
    if (value.isEmpty) return value;
    var result = value.replaceAll(_url, urlReplacement);
    result = result.replaceAll(_authorization, replacement);
    result = result.replaceAllMapped(
      _sensitivePair,
      (match) => '${match.group(1)}$replacement',
    );
    result = result.replaceAllMapped(
      _sensitiveArgument,
      (match) => '${match.group(1)}$replacement',
    );
    result = result.replaceAllMapped(
      _profileLabel,
      (match) => '${match.group(1)}$replacement',
    );
    result = result.replaceAllMapped(
      _rawPayload,
      (match) => '${match.group(1)}$replacement',
    );
    return result;
  }

  static String redactBounded(
    String value, {
    String prefix = '',
    int maxUtf8Bytes = diagnosticEntryByteLimit,
  }) {
    final boundedPrefix = truncateDiagnosticUtf8(
      prefix,
      maxBytes: maxUtf8Bytes,
      suffix: '',
    );
    final prefixBytes = diagnosticUtf8Length(boundedPrefix);
    final boundedValue = truncateDiagnosticUtf8(
      value,
      maxBytes: maxUtf8Bytes - prefixBytes,
    );
    final wasTruncated =
        boundedPrefix.length != prefix.length ||
        boundedValue.length != value.length ||
        boundedValue.endsWith(diagnosticTruncationMarker);
    final redacted = redact('$boundedPrefix$boundedValue');
    if (!wasTruncated) {
      return truncateDiagnosticUtf8(redacted, maxBytes: maxUtf8Bytes);
    }
    if (redacted.endsWith(diagnosticTruncationMarker)) {
      return truncateDiagnosticUtf8(redacted, maxBytes: maxUtf8Bytes);
    }
    final markerBytes = diagnosticUtf8Length(diagnosticTruncationMarker);
    if (markerBytes > maxUtf8Bytes) {
      return truncateDiagnosticUtf8(
        redacted,
        maxBytes: maxUtf8Bytes,
        suffix: '',
      );
    }
    final content = truncateDiagnosticUtf8(
      redacted,
      maxBytes: maxUtf8Bytes - markerBytes,
      suffix: '',
    );
    return '$content$diagnosticTruncationMarker';
  }
}
