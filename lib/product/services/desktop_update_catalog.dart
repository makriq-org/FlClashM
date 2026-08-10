import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'app_update_manifest.dart';
import 'app_update_release.dart';

const desktopUpdateCatalogSchemaVersion = 1;
const desktopUpdateCatalogRootUrl = '$sourceForgeUpdateRootUrl/desktop';

enum DesktopUpdateOperatingSystem {
  linux('linux'),
  windows('windows'),
  macos('macos');

  const DesktopUpdateOperatingSystem(this.wireName);
  final String wireName;
}

enum DesktopUpdateArchitecture {
  x64('x86_64'),
  arm64('arm64');

  const DesktopUpdateArchitecture(this.wireName);
  final String wireName;
}

enum DesktopPackageKind {
  appImage('appimage'),
  windowsInstaller('windows-installer'),
  macosAppArchive('macos-app-archive');

  const DesktopPackageKind(this.wireName);
  final String wireName;
}

class DesktopUpdateTarget {
  const DesktopUpdateTarget({
    required this.operatingSystem,
    required this.architecture,
    required this.packageKind,
  });

  final DesktopUpdateOperatingSystem operatingSystem;
  final DesktopUpdateArchitecture architecture;
  final DesktopPackageKind packageKind;

  String get key =>
      '${operatingSystem.wireName}/${architecture.wireName}/${packageKind.wireName}';
}

class DesktopUpdateCatalog {
  const DesktopUpdateCatalog({
    required this.catalogId,
    required this.channel,
    required this.tagName,
    required this.versionName,
    required this.versionCode,
    required this.publishedAt,
    required this.body,
    required this.htmlUrl,
    required this.assets,
  });

  factory DesktopUpdateCatalog.fromJson(
    Map<String, dynamic> json, {
    required AppUpdateChannel expectedChannel,
  }) {
    if (json['schemaVersion'] != desktopUpdateCatalogSchemaVersion) {
      throw const FormatException('Unsupported desktop update catalog schema.');
    }
    if (json['channel'] != expectedChannel.wireName) {
      throw const FormatException('Unexpected desktop update channel.');
    }
    final catalogId = _requiredString(json, 'catalogId');
    if (!RegExp(r'^[a-z0-9][a-z0-9.-]{0,63}$').hasMatch(catalogId)) {
      throw const FormatException('Invalid desktop update catalog ID.');
    }
    final release = json['release'];
    if (release is! Map) {
      throw const FormatException('Missing desktop update release.');
    }
    final releaseJson = Map<String, dynamic>.from(release);
    final tagName = _requiredString(releaseJson, 'tagName');
    final versionName = _requiredString(releaseJson, 'versionName');
    final versionCode = releaseJson['versionCode'];
    if (!appUpdateReleaseTagPattern.hasMatch(tagName) ||
        tagName.substring(1) != versionName ||
        !appUpdateReleaseTagMatchesChannel(tagName, expectedChannel)) {
      throw const FormatException('Invalid desktop update release version.');
    }
    if (versionCode is! int || versionCode <= 0) {
      throw const FormatException('Invalid desktop update version code.');
    }
    final publishedAt = DateTime.tryParse(
      _requiredString(releaseJson, 'publishedAt'),
    );
    if (publishedAt == null || !publishedAt.isUtc) {
      throw const FormatException('Invalid desktop update publication time.');
    }
    final body = releaseJson['body'];
    if (body is! String) {
      throw const FormatException('Invalid desktop update release notes.');
    }
    final htmlUrl = _requiredHttpsUrl(releaseJson, 'htmlUrl');
    final rawAssets = releaseJson['assets'];
    if (rawAssets is! List || rawAssets.isEmpty) {
      throw const FormatException('Missing desktop update assets.');
    }
    final assets = <DesktopUpdateCatalogAsset>[];
    final targetKeys = <String>{};
    final names = <String>{};
    for (final rawAsset in rawAssets) {
      if (rawAsset is! Map) {
        throw const FormatException('Invalid desktop update asset.');
      }
      final asset = DesktopUpdateCatalogAsset.fromJson(
        Map<String, dynamic>.from(rawAsset),
      );
      if (!targetKeys.add(asset.target.key)) {
        throw const FormatException('Duplicate desktop update target.');
      }
      if (!names.add(asset.name)) {
        throw const FormatException('Duplicate desktop update asset name.');
      }
      assets.add(asset);
    }

    return DesktopUpdateCatalog(
      catalogId: catalogId,
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

  final String catalogId;
  final AppUpdateChannel channel;
  final String tagName;
  final String versionName;
  final int versionCode;
  final DateTime publishedAt;
  final String body;
  final String htmlUrl;
  final List<DesktopUpdateCatalogAsset> assets;

  DesktopUpdateCatalogAsset select(DesktopUpdateTarget target) {
    final matches = assets.where((asset) => asset.target.key == target.key);
    if (matches.length != 1) {
      throw FormatException(
        'Desktop update target `${target.key}` is unavailable or ambiguous.',
      );
    }
    return matches.single;
  }

  AppRelease toRelease() => AppRelease(
        tagName: tagName,
        body: body,
        htmlUrl: htmlUrl,
        assets: assets.map((asset) => asset.toReleaseAsset()).toList(),
        prerelease: channel == AppUpdateChannel.prerelease,
        draft: false,
        versionCode: versionCode,
        catalogId: catalogId,
      );
}

class DesktopUpdateCatalogAsset {
  const DesktopUpdateCatalogAsset({
    required this.target,
    required this.name,
    required this.size,
    required this.sha256,
    required this.urls,
  });

  factory DesktopUpdateCatalogAsset.fromJson(Map<String, dynamic> json) {
    final os = _parseEnum(
      DesktopUpdateOperatingSystem.values,
      _requiredString(json, 'os'),
      (value) => value.wireName,
      'operating system',
    );
    final architecture = _parseEnum(
      DesktopUpdateArchitecture.values,
      _requiredString(json, 'arch'),
      (value) => value.wireName,
      'architecture',
    );
    final packageKind = _parseEnum(
      DesktopPackageKind.values,
      _requiredString(json, 'packageKind'),
      (value) => value.wireName,
      'package kind',
    );
    _validateCombination(os, architecture, packageKind);

    final name = _requiredString(json, 'name');
    if (name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains(r'\') ||
        name.contains('\u0000')) {
      throw const FormatException('Invalid desktop update asset name.');
    }
    final validPackageName = name.startsWith('FlClashM') &&
        switch (packageKind) {
          DesktopPackageKind.appImage => name.endsWith('.AppImage'),
          DesktopPackageKind.windowsInstaller =>
            name.endsWith('.exe') || name.endsWith('.msi'),
          DesktopPackageKind.macosAppArchive => name.endsWith('.zip'),
        };
    if (!validPackageName) {
      throw const FormatException(
        'Desktop update asset is not a full application package.',
      );
    }
    final size = json['size'];
    if (size is! int || size <= 0) {
      throw const FormatException('Invalid desktop update asset size.');
    }
    final sha256 = _requiredString(json, 'sha256').toLowerCase();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const FormatException('Invalid desktop update asset SHA256.');
    }
    final rawUrls = json['urls'];
    if (rawUrls is! List || rawUrls.isEmpty) {
      throw const FormatException('Missing desktop update asset mirrors.');
    }
    final urls = <String>[];
    final uniqueUrls = <String>{};
    for (final rawUrl in rawUrls) {
      final url = rawUrl?.toString() ?? '';
      final uri = Uri.tryParse(url);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          !uniqueUrls.add(url)) {
        throw const FormatException('Invalid desktop update asset mirror.');
      }
      urls.add(url);
    }
    return DesktopUpdateCatalogAsset(
      target: DesktopUpdateTarget(
        operatingSystem: os,
        architecture: architecture,
        packageKind: packageKind,
      ),
      name: name,
      size: size,
      sha256: sha256,
      urls: List.unmodifiable(urls),
    );
  }

  final DesktopUpdateTarget target;
  final String name;
  final int size;
  final String sha256;
  final List<String> urls;

  ReleaseAsset toReleaseAsset() => ReleaseAsset(
        name: name,
        browserDownloadUrl: urls.first,
        downloadUrls: urls,
        size: size,
        digest: 'sha256:$sha256',
      );
}

class DesktopUpdateCatalogVerifier {
  const DesktopUpdateCatalogVerifier({
    this.publicKeyBase64 = appUpdateManifestPublicKeyBase64,
  });

  final String publicKeyBase64;

  Future<DesktopUpdateCatalog> verifyAndDecode({
    required List<int> catalogBytes,
    required List<int> signatureBytes,
    required AppUpdateChannel expectedChannel,
  }) async {
    final publicKeyBytes = base64Decode(publicKeyBase64);
    if (publicKeyBytes.length != 32 || signatureBytes.length != 64) {
      throw const FormatException('Invalid desktop update signature material.');
    }
    final publicKey = SimplePublicKey(
      publicKeyBytes,
      type: KeyPairType.ed25519,
    );
    if (!await Ed25519().verify(
      catalogBytes,
      signature: Signature(signatureBytes, publicKey: publicKey),
    )) {
      throw const FormatException('Invalid desktop update catalog signature.');
    }
    final decoded = jsonDecode(utf8.decode(catalogBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid desktop update catalog document.');
    }
    return DesktopUpdateCatalog.fromJson(
      decoded,
      expectedChannel: expectedChannel,
    );
  }
}

String desktopUpdateCatalogUrl(AppUpdateChannel channel) =>
    '$desktopUpdateCatalogRootUrl/${channel.wireName}.json';

String desktopUpdateCatalogSignatureUrl(AppUpdateChannel channel) =>
    '${desktopUpdateCatalogUrl(channel)}.sig';

void _validateCombination(
  DesktopUpdateOperatingSystem operatingSystem,
  DesktopUpdateArchitecture architecture,
  DesktopPackageKind packageKind,
) {
  final supported = switch ((operatingSystem, architecture, packageKind)) {
    (
      DesktopUpdateOperatingSystem.linux,
      DesktopUpdateArchitecture.x64,
      DesktopPackageKind.appImage,
    ) =>
      true,
    (
      DesktopUpdateOperatingSystem.windows,
      DesktopUpdateArchitecture.x64,
      DesktopPackageKind.windowsInstaller,
    ) =>
      true,
    (
      DesktopUpdateOperatingSystem.macos,
      DesktopUpdateArchitecture.x64 || DesktopUpdateArchitecture.arm64,
      DesktopPackageKind.macosAppArchive,
    ) =>
      true,
    _ => false,
  };
  if (!supported) {
    throw const FormatException('Unsupported desktop update target.');
  }
}

T _parseEnum<T>(
  List<T> values,
  String raw,
  String Function(T value) wireName,
  String label,
) {
  for (final value in values) {
    if (wireName(value) == raw) return value;
  }
  throw FormatException('Unsupported desktop update $label.');
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Missing desktop update field `$key`.');
  }
  return value;
}

String _requiredHttpsUrl(Map<String, dynamic> json, String key) {
  final value = _requiredString(json, key);
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw FormatException('Invalid desktop update URL field `$key`.');
  }
  return value;
}
