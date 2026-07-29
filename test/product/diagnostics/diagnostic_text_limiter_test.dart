import 'package:flclashx/product/diagnostics/diagnostic_text_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('truncates multibyte input on a UTF-8 boundary', () {
    final result = truncateDiagnosticUtf8('界' * 100, maxBytes: 64);

    expect(diagnosticUtf8Length(result), lessThanOrEqualTo(64));
    expect(result, endsWith(diagnosticTruncationMarker));
    expect(result, isNot(contains('\uFFFD')));
  });

  test('keeps exact-limit input without a marker', () {
    expect(
      truncateDiagnosticUtf8('界界', maxBytes: 6),
      '界界',
    );
  });
}
