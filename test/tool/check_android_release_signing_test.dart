import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_android_release_signing.dart';

void main() {
  group('tryParseSignerInfo', () {
    test('parses legacy apksigner output', () {
      const output = '''
Signer #1 certificate DN: CN=FlClashM Release, O=makriq, C=RU
Signer #1 certificate SHA-256 digest: e2425bde9387081e3259b4794b9868513ddaa0076ab5045909ce4f96f23a0672
''';

      final signerInfo = tryParseSignerInfo(output);

      expect(signerInfo, isNotNull);
      expect(
        signerInfo!.subjectDn,
        'CN=FlClashM Release, O=makriq, C=RU',
      );
      expect(
        signerInfo.sha256,
        'e2425bde9387081e3259b4794b9868513ddaa0076ab5045909ce4f96f23a0672',
      );
    });

    test('parses current apksigner output', () {
      const output = '''
V2 Signer: certificate DN: CN=FlClashM Release, O=makriq, C=RU
V2 Signer: certificate SHA-256 digest: e2425bde9387081e3259b4794b9868513ddaa0076ab5045909ce4f96f23a0672
V2 Signer: certificate SHA-1 digest: d5e4ab152855fc2d91dd9616520b5188dc9cb852
''';

      final signerInfo = tryParseSignerInfo(output);

      expect(signerInfo, isNotNull);
      expect(
        signerInfo!.subjectDn,
        'CN=FlClashM Release, O=makriq, C=RU',
      );
      expect(
        signerInfo.sha256,
        'e2425bde9387081e3259b4794b9868513ddaa0076ab5045909ce4f96f23a0672',
      );
    });
  });
}
