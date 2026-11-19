import 'package:flutter/foundation.dart';

/// Identity Android reports for an installed package or for an APK archive.
///
/// Signers are SHA-256 digests of the signing certificates, lowercase hex, so
/// the whole identity survives the method-channel trip as plain data.
@immutable
class AppUpdatePackageIdentity {
  const AppUpdatePackageIdentity({
    required this.packageName,
    required this.versionCode,
    required this.signers,
  });

  /// Null when the platform answered something that is not an identity.
  static AppUpdatePackageIdentity? tryFromMap(Object? map) {
    if (map is! Map) {
      return null;
    }
    final packageName = map['packageName'];
    final versionCode = map['versionCode'];
    final signers = map['signers'];
    if (packageName is! String ||
        packageName.trim().isEmpty ||
        versionCode is! int ||
        versionCode <= 0 ||
        signers is! List) {
      return null;
    }
    final digests = <String>{};
    for (final signer in signers) {
      if (signer is! String) {
        return null;
      }
      final digest = signer.trim().toLowerCase();
      if (!_signerPattern.hasMatch(digest)) {
        return null;
      }
      digests.add(digest);
    }
    return AppUpdatePackageIdentity(
      packageName: packageName,
      versionCode: versionCode,
      signers: Set.unmodifiable(digests),
    );
  }

  final String packageName;
  final int versionCode;

  /// SHA-256 of each signing certificate; empty when the APK is unsigned.
  final Set<String> signers;

  /// The digest shown to the user: the lowest one, so the text is stable.
  String get signerFingerprint {
    final ordered = signers.toList()..sort();
    return ordered.isEmpty ? '' : ordered.first;
  }

  @override
  bool operator ==(Object other) =>
      other is AppUpdatePackageIdentity &&
      other.packageName == packageName &&
      other.versionCode == versionCode &&
      setEquals(other.signers, signers);

  @override
  int get hashCode =>
      Object.hash(packageName, versionCode, Object.hashAllUnordered(signers));
}

final _signerPattern = RegExp(r'^[a-f0-9]{64}$');

enum AppUpdateIdentityFailure {
  /// Android could not describe the running app.
  installedUnavailable,

  /// Android could not describe the downloaded APK.
  candidateUnavailable,

  /// The APK belongs to another package.
  package,

  /// The APK is signed by another key (or not signed at all).
  signer,

  /// The APK would install the same or an older build.
  notNewer,

  /// The APK is not the build the signed catalog describes.
  versionMismatch,
}

class AppUpdateIdentityException implements Exception {
  const AppUpdateIdentityException(this.failure, [this.detail]);

  final AppUpdateIdentityFailure failure;
  final String? detail;

  @override
  String toString() => detail == null
      ? 'app update identity rejected: ${failure.name}'
      : 'app update identity rejected: ${failure.name} ($detail)';
}

/// Refuses an APK that is not this app, not signed the way the installed app
/// is, or not newer. The installer would refuse most of this too; refusing
/// here turns a silent failure into a message.
void checkAppUpdateIdentity({
  required AppUpdatePackageIdentity? installed,
  required AppUpdatePackageIdentity? candidate,
  int? expectedVersionCode,
}) {
  if (installed == null) {
    throw const AppUpdateIdentityException(
      AppUpdateIdentityFailure.installedUnavailable,
    );
  }
  if (candidate == null) {
    throw const AppUpdateIdentityException(
      AppUpdateIdentityFailure.candidateUnavailable,
    );
  }
  if (candidate.packageName != installed.packageName) {
    throw AppUpdateIdentityException(
      AppUpdateIdentityFailure.package,
      candidate.packageName,
    );
  }
  if (candidate.signers.isEmpty ||
      !setEquals(candidate.signers, installed.signers)) {
    throw const AppUpdateIdentityException(AppUpdateIdentityFailure.signer);
  }
  if (expectedVersionCode != null &&
      candidate.versionCode != expectedVersionCode) {
    throw AppUpdateIdentityException(
      AppUpdateIdentityFailure.versionMismatch,
      '${candidate.versionCode} != $expectedVersionCode',
    );
  }
  if (candidate.versionCode <= installed.versionCode) {
    throw AppUpdateIdentityException(
      AppUpdateIdentityFailure.notNewer,
      '${candidate.versionCode} <= ${installed.versionCode}',
    );
  }
}
