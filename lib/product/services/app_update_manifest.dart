import 'dart:convert';

import 'package:cryptography/cryptography.dart';

const appUpdateManifestSchemaVersion = 1;
const appUpdateManifestPublicKeyBase64 =
    'S5W0qI3x7cXrnGhbrL4YV9JwCJSrASo+Tu2gkgKSGaw=';
const sourceForgeProjectName = 'flclashm';
const sourceForgeProjectUrl =
    'https://sourceforge.net/projects/$sourceForgeProjectName';
const sourceForgeUpdateRootUrl =
    'https://$sourceForgeProjectName.sourceforge.io/update';
final appUpdateReleaseTagPattern =
    RegExp(r'^v\d+(?:\.\d+)*(?:-[0-9A-Za-z.-]+)?$');
final appUpdateAndroidApkAssetPattern = RegExp(
  r'-android(?:-([A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*))?\.apk$',
);

enum AppUpdateChannel {
  stable('stable'),
  prerelease('pre');

  const AppUpdateChannel(this.wireName);

  final String wireName;
}

class AppUpdateManifest {
  const AppUpdateManifest({
    required this.channel,
    required this.tagName,
    required this.versionName,
    required this.versionCode,
    required this.publishedAt,
    required this.body,
    required this.htmlUrl,
    required this.assets,
  });

  factory AppUpdateManifest.fromJson(
    Map<String, dynamic> json, {
    required AppUpdateChannel expectedChannel,
  }) {
    final schemaVersion = json['schemaVersion'];
    if (schemaVersion != appUpdateManifestSchemaVersion) {
      throw const FormatException('Unsupported app update manifest schema.');
    }

    final channel = json['channel']?.toString();
    if (channel != expectedChannel.wireName) {
      throw const FormatException('Unexpected app update channel.');
    }

    final release = json['release'];
    if (release is! Map) {
      throw const FormatException('Missing app update release.');
    }
    final releaseJson = Map<String, dynamic>.from(release);
    final tagName = _requiredString(releaseJson, 'tagName');
    final versionName = _requiredString(releaseJson, 'versionName');
    final versionCode = releaseJson['versionCode'];
    final publishedAtRaw = _requiredString(releaseJson, 'publishedAt');
    final htmlUrl = _requiredHttpsUrl(releaseJson, 'htmlUrl');
    final body = releaseJson['body'];
    if (!appUpdateReleaseTagPattern.hasMatch(tagName) ||
        tagName.substring(1) != versionName) {
      throw const FormatException('Release tag and version do not match.');
    }
    if (!appUpdateReleaseTagMatchesChannel(tagName, expectedChannel)) {
      throw const FormatException('Release tag does not match update channel.');
    }
    if (versionCode is! int || versionCode <= 0) {
      throw const FormatException('Invalid app update version code.');
    }
    final publishedAt = DateTime.tryParse(publishedAtRaw);
    if (publishedAt == null || !publishedAt.isUtc) {
      throw const FormatException('Invalid app update publication time.');
    }
    if (body is! String) {
      throw const FormatException('Invalid app update release notes.');
    }

    final rawAssets = releaseJson['assets'];
    if (rawAssets is! List || rawAssets.isEmpty) {
      throw const FormatException('Missing app update assets.');
    }
    final assets = <AppUpdateManifestAsset>[];
    final names = <String>{};
    for (final rawAsset in rawAssets) {
      if (rawAsset is! Map) {
        throw const FormatException('Invalid app update asset.');
      }
      final asset = AppUpdateManifestAsset.fromJson(
        Map<String, dynamic>.from(rawAsset),
      );
      if (!names.add(asset.name)) {
        throw const FormatException('Duplicate app update asset name.');
      }
      assets.add(asset);
    }

    return AppUpdateManifest(
      channel: expectedChannel,
      tagName: tagName,
      versionName: versionName,
      versionCode: versionCode,
      publishedAt: publishedAt,
      body: body,
      htmlUrl: htmlUrl,
      assets: List.unmodifiable(assets),
    );
  }

  final AppUpdateChannel channel;
  final String tagName;
  final String versionName;
  final int versionCode;
  final DateTime publishedAt;
  final String body;
  final String htmlUrl;
  final List<AppUpdateManifestAsset> assets;

  Map<String, dynamic> toJson() => {
        'schemaVersion': appUpdateManifestSchemaVersion,
        'channel': channel.wireName,
        'release': {
          'tagName': tagName,
          'versionName': versionName,
          'versionCode': versionCode,
          'publishedAt': publishedAt.toUtc().toIso8601String(),
          'body': body,
          'htmlUrl': htmlUrl,
          'assets': assets.map((asset) => asset.toJson()).toList(),
        },
      };
}

class AppUpdateManifestAsset {
  const AppUpdateManifestAsset({
    required this.name,
    required this.size,
    required this.sha256,
    required this.urls,
  });

  factory AppUpdateManifestAsset.fromJson(Map<String, dynamic> json) {
    final name = _requiredString(json, 'name');
    final size = json['size'];
    final sha256 = _requiredString(json, 'sha256').toLowerCase();
    final rawUrls = json['urls'];
    if (name.contains(RegExp(r'[/\\]'))) {
      throw const FormatException('Invalid app update asset name.');
    }
    if (size is! int || size <= 0) {
      throw const FormatException('Invalid app update asset size.');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const FormatException('Invalid app update asset SHA256.');
    }
    if (rawUrls is! List || rawUrls.isEmpty) {
      throw const FormatException('Missing app update asset URLs.');
    }
    final urls = rawUrls.map((value) {
      final url = value?.toString() ?? '';
      final uri = Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        throw const FormatException('Invalid app update asset URL.');
      }
      return url;
    }).toList(growable: false);

    if (!isAppUpdateAndroidApkAssetName(name)) {
      throw const FormatException('Manifest asset is not an Android APK.');
    }

    return AppUpdateManifestAsset(
      name: name,
      size: size,
      sha256: sha256,
      urls: List.unmodifiable(urls),
    );
  }

  final String name;
  final int size;
  final String sha256;
  final List<String> urls;

  Map<String, dynamic> toJson() => {
        'name': name,
        'size': size,
        'sha256': sha256,
        'urls': urls,
      };
}

class AppUpdateManifestVerifier {
  const AppUpdateManifestVerifier({
    this.publicKeyBase64 = appUpdateManifestPublicKeyBase64,
  });

  final String publicKeyBase64;

  Future<AppUpdateManifest> verifyAndDecode({
    required List<int> manifestBytes,
    required List<int> signatureBytes,
    required AppUpdateChannel expectedChannel,
  }) async {
    final publicKeyBytes = base64Decode(publicKeyBase64);
    if (publicKeyBytes.length != 32 || signatureBytes.length != 64) {
      throw const FormatException('Invalid app update signature material.');
    }
    final publicKey = SimplePublicKey(
      publicKeyBytes,
      type: KeyPairType.ed25519,
    );
    final verified = await Ed25519().verify(
      manifestBytes,
      signature: Signature(signatureBytes, publicKey: publicKey),
    );
    if (!verified) {
      throw const FormatException('Invalid app update manifest signature.');
    }

    final decoded = jsonDecode(utf8.decode(manifestBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid app update manifest document.');
    }
    return AppUpdateManifest.fromJson(
      decoded,
      expectedChannel: expectedChannel,
    );
  }
}

String appUpdateManifestUrl(AppUpdateChannel channel) =>
    '$sourceForgeUpdateRootUrl/${channel.wireName}.json';

String appUpdateManifestSignatureUrl(AppUpdateChannel channel) =>
    '${appUpdateManifestUrl(channel)}.sig';

bool appUpdateReleaseTagMatchesChannel(
  String tagName,
  AppUpdateChannel channel,
) =>
    (channel == AppUpdateChannel.prerelease) == tagName.contains('-');

bool isAppUpdateAndroidApkAssetName(String name) =>
    appUpdateAndroidApkAssetPattern.hasMatch(name);

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Missing app update field `$key`.');
  }
  return value;
}

String _requiredHttpsUrl(Map<String, dynamic> json, String key) {
  final value = _requiredString(json, key);
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    throw FormatException('Invalid app update URL field `$key`.');
  }
  return value;
}
