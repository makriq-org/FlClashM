import 'package:flclashx/product/services/app_update_identity.dart';
import 'package:flutter_test/flutter_test.dart';

final _signer = 'a' * 64;
final _otherSigner = 'b' * 64;

AppUpdatePackageIdentity identity({
  String packageName = 'com.makriq.flclash',
  int versionCode = 2026111801,
  Set<String>? signers,
}) => AppUpdatePackageIdentity(
  packageName: packageName,
  versionCode: versionCode,
  signers: signers ?? {_signer},
);

void main() {
  group('AppUpdatePackageIdentity.tryFromMap', () {
    test('accepts the map the platform channel returns', () {
      final parsed = AppUpdatePackageIdentity.tryFromMap({
        'packageName': 'com.makriq.flclash',
        'versionCode': 2026111801,
        'signers': [_signer.toUpperCase()],
      });

      expect(parsed, identity());
      expect(parsed?.signerFingerprint, _signer);
    });

    test('rejects an answer without a usable version code or digest', () {
      expect(
        AppUpdatePackageIdentity.tryFromMap({
          'packageName': 'com.makriq.flclash',
          'versionCode': 0,
          'signers': [_signer],
        }),
        isNull,
      );
      expect(
        AppUpdatePackageIdentity.tryFromMap({
          'packageName': 'com.makriq.flclash',
          'versionCode': 1,
          'signers': ['not-a-digest'],
        }),
        isNull,
      );
      expect(AppUpdatePackageIdentity.tryFromMap(null), isNull);
      expect(AppUpdatePackageIdentity.tryFromMap('oops'), isNull);
    });
  });

  group('checkAppUpdateIdentity', () {
    test('accepts the next build of this app signed with the same key', () {
      checkAppUpdateIdentity(
        installed: identity(versionCode: 2026110101),
        candidate: identity(versionCode: 2026111801),
        expectedVersionCode: 2026111801,
      );
    });

    test('refuses another package', () {
      expect(
        () => checkAppUpdateIdentity(
          installed: identity(),
          candidate: identity(packageName: 'com.example.other'),
        ),
        throwsA(
          isA<AppUpdateIdentityException>().having(
            (error) => error.failure,
            'failure',
            AppUpdateIdentityFailure.package,
          ),
        ),
      );
    });

    test('refuses an APK signed by another certificate or unsigned', () {
      expect(
        () => checkAppUpdateIdentity(
          installed: identity(),
          candidate: identity(signers: {_otherSigner}),
        ),
        throwsA(
          isA<AppUpdateIdentityException>().having(
            (error) => error.failure,
            'failure',
            AppUpdateIdentityFailure.signer,
          ),
        ),
      );
      expect(
        () => checkAppUpdateIdentity(
          installed: identity(),
          candidate: identity(signers: const <String>{}),
        ),
        throwsA(isA<AppUpdateIdentityException>()),
      );
    });

    test('refuses an APK that does not match the signed catalog', () {
      expect(
        () => checkAppUpdateIdentity(
          installed: identity(versionCode: 1),
          candidate: identity(versionCode: 2026111801),
          expectedVersionCode: 2026111802,
        ),
        throwsA(
          isA<AppUpdateIdentityException>().having(
            (error) => error.failure,
            'failure',
            AppUpdateIdentityFailure.versionMismatch,
          ),
        ),
      );
    });

    test('refuses the same or an older build', () {
      expect(
        () => checkAppUpdateIdentity(
          installed: identity(versionCode: 2026111801),
          candidate: identity(versionCode: 2026111801),
        ),
        throwsA(
          isA<AppUpdateIdentityException>().having(
            (error) => error.failure,
            'failure',
            AppUpdateIdentityFailure.notNewer,
          ),
        ),
      );
    });

    test('refuses when Android cannot describe either side', () {
      expect(
        () => checkAppUpdateIdentity(installed: null, candidate: identity()),
        throwsA(
          isA<AppUpdateIdentityException>().having(
            (error) => error.failure,
            'failure',
            AppUpdateIdentityFailure.installedUnavailable,
          ),
        ),
      );
      expect(
        () => checkAppUpdateIdentity(installed: identity(), candidate: null),
        throwsA(
          isA<AppUpdateIdentityException>().having(
            (error) => error.failure,
            'failure',
            AppUpdateIdentityFailure.candidateUnavailable,
          ),
        ),
      );
    });
  });
}
