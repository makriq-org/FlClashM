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
    r'''(["']?(?:password|passwd|pwd|token|access[_-]?token|refresh[_-]?token|secret|authorization|proxy[_-]?authorization|api[_-]?key|apikey|subscription(?:[_-]?url)?|support[_-]?url|name|profile[_-]?(?:name|title)|currentProfileName|node[_-]?name)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}\]]+)''',
    caseSensitive: false,
  );
  static final RegExp _sensitiveArgument = RegExp(
    r'''(--(?:password|passwd|token|secret|authorization|api[_-]?key|subscription[_-]?url|support[_-]?url)(?:=|\s+))(?:"[^"]*"|'[^']*'|[^\s]+)''',
    caseSensitive: false,
  );
  static final RegExp _profileLabel = RegExp(
    r'''(\b(?:profile|node)\s+(?:name\s+)?)(?:`[^`]*`|"[^"]*"|'[^']*')''',
    caseSensitive: false,
  );
  static final RegExp _rawPayload = RegExp(
    r'''(\b(?:raw(?:[_-]?(?:config|data|payload))?|config|data|payload|params|ipc[_-]?payload|quickstart[_-]?params|profile[_-]?yaml|subscription[_-]?content)\s*[:=]\s*)(?:\{.*|\[.*|.+)$''',
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
}
