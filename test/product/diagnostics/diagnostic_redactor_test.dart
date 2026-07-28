import 'package:flclashx/product/diagnostics/diagnostic_redactor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('redacts credentials, URLs, profile names and raw payloads', () {
    const secrets = <String>[
      'hunter2',
      'abc123',
      'very-secret-token',
      'user:pass',
      '/sub/private',
      'My private profile',
      'Node from JSON',
      '"proxies"',
      'inside-config',
      'second-line-secret',
    ];
    final input = [
      'password: "hunter2" token=abc123',
      'Authorization: Bearer very-secret-token',
      'subscription_url=https://user:pass@example.com/sub/private?token=abc',
      'profile `My private profile` failed',
      'raw config={"proxies":[{"password":"inside-config"}]}',
      'name: "Node from JSON"',
      'ipc payload={\n  "password": "second-line-secret"\n}',
    ].join('\n');

    final redacted = DiagnosticRedactor.redact(input);

    for (final secret in secrets) {
      expect(redacted, isNot(contains(secret)), reason: secret);
    }
    expect(redacted, contains(DiagnosticRedactor.replacement));
  });

  test('keeps useful non-secret lifecycle context', () {
    const input =
        'FlVpnService cold-start failed on Android API 35 with exit code 2';

    expect(DiagnosticRedactor.redact(input), input);
  });
}
