import 'package:flclashx/product/services/app_update_manifest.dart';
import 'package:flclashx/product/services/app_update_mirrors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('appUpdateMirrorManifestUri', () {
    test('turns a catalog directory into the channel pointer', () {
      expect(
        appUpdateMirrorManifestUri(
          'https://mirror.example/update',
          channel: AppUpdateChannel.stable,
        ).toString(),
        'https://mirror.example/update/stable.json',
      );
      expect(
        appUpdateMirrorManifestUri(
          'https://mirror.example/update/',
          channel: AppUpdateChannel.prerelease,
        ).toString(),
        'https://mirror.example/update/pre.json',
      );
    });

    test('keeps an explicit pointer of the same channel', () {
      expect(
        appUpdateMirrorManifestUri(
          'https://mirror.example/pre.json',
          channel: AppUpdateChannel.prerelease,
        ).toString(),
        'https://mirror.example/pre.json',
      );
    });

    test('refuses a pointer of the other channel', () {
      expect(
        appUpdateMirrorManifestUri(
          'https://mirror.example/update/pre.json',
          channel: AppUpdateChannel.stable,
        ),
        isNull,
      );
    });

    test('refuses anything that is not a plain HTTPS address', () {
      for (final value in [
        null,
        '',
        'http://mirror.example/update',
        'https://user:pass@mirror.example/update',
        'https://mirror.example:8443/update',
        'https://mirror.example/update?channel=stable',
        'https://mirror.example/update#fragment',
        'https://mirror.example/',
        'not a url',
      ]) {
        expect(
          appUpdateMirrorManifestUri(
            value,
            channel: AppUpdateChannel.stable,
          ),
          isNull,
          reason: '$value',
        );
      }
    });

    test('builds the signature address next to the pointer', () {
      expect(
        appUpdateSignatureUriOf(
          Uri.parse('https://mirror.example/update/stable.json'),
        ).toString(),
        'https://mirror.example/update/stable.json.sig',
      );
    });
  });

  group('AppUpdateMirrorSnapshot', () {
    test('takes both channel mirrors from the subscription headers', () {
      final snapshot = AppUpdateMirrorSnapshot.fromHeaders(
        profileId: 'profile-1',
        headers: const {
          appUpdateMirrorHeaderStable: 'https://mirror.example/update',
          appUpdateMirrorHeaderPrerelease: 'https://mirror.example/pre/',
        },
      );

      expect(
        snapshot.manifestFor(AppUpdateChannel.stable).toString(),
        'https://mirror.example/update/stable.json',
      );
      expect(
        snapshot.manifestFor(AppUpdateChannel.prerelease).toString(),
        'https://mirror.example/pre/pre.json',
      );
      expect(snapshot.isEmpty, isFalse);
    });

    test('keeps one channel when the other header is broken', () {
      final snapshot = AppUpdateMirrorSnapshot.fromHeaders(
        profileId: 'profile-1',
        headers: const {
          appUpdateMirrorHeaderStable: 'http://mirror.example/update',
          appUpdateMirrorHeaderPrerelease: 'https://mirror.example/pre',
        },
      );

      expect(snapshot.manifestFor(AppUpdateChannel.stable), isNull);
      expect(snapshot.manifestFor(AppUpdateChannel.prerelease), isNotNull);
    });

    test('is empty without headers', () {
      final snapshot = AppUpdateMirrorSnapshot.fromHeaders(
        profileId: 'profile-1',
        headers: const {},
      );

      expect(snapshot.isEmpty, isTrue);
      expect(
        snapshot.sameDecisionContextAs(AppUpdateMirrorSnapshot.empty),
        isTrue,
      );
    });

    test('a different profile or address is a different decision context', () {
      AppUpdateMirrorSnapshot snapshot(String profileId, String url) =>
          AppUpdateMirrorSnapshot.fromHeaders(
            profileId: profileId,
            headers: {appUpdateMirrorHeaderStable: url},
          );

      final first = snapshot('profile-1', 'https://a.example/update');
      expect(
        first.sameDecisionContextAs(
          snapshot('profile-1', 'https://a.example/update'),
        ),
        isTrue,
      );
      expect(
        first.sameDecisionContextAs(
          snapshot('profile-2', 'https://a.example/update'),
        ),
        isFalse,
      );
      expect(
        first.sameDecisionContextAs(
          snapshot('profile-1', 'https://b.example/update'),
        ),
        isFalse,
      );
    });
  });
}
