import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_android_release_signing.dart';

void main() {
  group('tryParseApkSignerInfo', () {
    test('parses legacy apksigner output', () {
      const output = '''
Signer #1 certificate DN: CN=FlClashM Release, O=makriq, C=RU
Signer #1 certificate SHA-256 digest: e2425bde9387081e3259b4794b9868513ddaa0076ab5045909ce4f96f23a0672
''';

      final signerInfo = tryParseApkSignerInfo(output);

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

      final signerInfo = tryParseApkSignerInfo(output);

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

  test('parses keytool AAB output', () {
    const output = '''
Owner: CN=FlClashM Release, O=makriq, C=RU
Issuer: CN=FlClashM Release, O=makriq, C=RU
Certificate fingerprints:
         SHA256: E2:42:5B:DE:93:87:08:1E:32:59:B4:79:4B:98:68:51:3D:DA:A0:07:6A:B5:04:59:09:CE:4F:96:F2:3A:06:72
''';

    final signerInfo = tryParseAabSignerInfo(output);

    expect(signerInfo, isNotNull);
    expect(signerInfo!.subjectDn, 'CN=FlClashM Release, O=makriq, C=RU');
    expect(
      signerInfo.sha256,
      'e2425bde9387081e3259b4794b9868513ddaa0076ab5045909ce4f96f23a0672',
    );
  });
}
