import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flclashm/common/common.dart';

class ReleaseAsset {
  ReleaseAsset({
    required this.name,
    required this.browserDownloadUrl,
    required this.size,
    this.digest,
  });

  factory ReleaseAsset.fromJson(Map<String, dynamic> json) => ReleaseAsset(
        name: json['name']?.toString() ?? '',
        browserDownloadUrl: json['browser_download_url']?.toString() ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        digest: json['digest']?.toString(),
      );

  static final RegExp _androidAssetPattern = RegExp(
    r'-android(?:-([A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*))?\.apk$',
  );

  final String name;
  final String browserDownloadUrl;
  final int size;
  final String? digest;

  bool get isAndroidApk => _androidAssetPattern.hasMatch(name);

  String? get androidAbi {
    final match = _androidAssetPattern.firstMatch(name);
    if (match == null) {
      return null;
    }
    return match.group(1);
  }

  String? get sha256Digest {
    final value = digest;
    if (value == null || !value.startsWith('sha256:')) {
      return null;
    }
    final parsed = value.substring('sha256:'.length).trim().toLowerCase();
    return _sha256Pattern.hasMatch(parsed) ? parsed : null;
  }
}

class AppRelease {
  AppRelease({
    required this.tagName,
    required this.body,
    required this.htmlUrl,
    required this.assets,
    required this.prerelease,
    required this.draft,
  });

  factory AppRelease.fromJson(Map<String, dynamic> json) {
    final rawAssets = json['assets'];
    final assets = rawAssets is List
        ? rawAssets
            .whereType<Map>()
            .map((item) =>
                ReleaseAsset.fromJson(Map<String, dynamic>.from(item)))
            .toList()
        : <ReleaseAsset>[];
    return AppRelease(
      tagName: json['tag_name']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      htmlUrl: json['html_url']?.toString() ?? '',
      assets: assets,
      prerelease: json['prerelease'] as bool? ?? false,
      draft: json['draft'] as bool? ?? false,
    );
  }

  final String tagName;
  final String body;
  final String htmlUrl;
  final List<ReleaseAsset> assets;
  final bool prerelease;
  final bool draft;

  String get version =>
      tagName.startsWith('v') ? tagName.substring(1) : tagName;

  ReleaseAsset? findSha256AssetFor(ReleaseAsset asset) {
    final expectedName = '${asset.name}.sha256';
    for (final candidate in assets) {
      if (candidate.name == expectedName) {
        return candidate;
      }
    }
    return null;
  }
}

class AndroidReleaseAsset {
  const AndroidReleaseAsset({
    required this.apkAsset,
    required this.abi,
    this.checksumAsset,
  });

  final ReleaseAsset apkAsset;
  final String abi;
  final ReleaseAsset? checksumAsset;
}

const _sha256PatternSource = r'^[a-f0-9]{64}$';
final _sha256Pattern = RegExp(_sha256PatternSource);

AndroidReleaseAsset? selectAndroidReleaseAsset(
  AppRelease release, {
  required List<String> supportedAbis,
}) {
  final abiAssetMap = <String, ReleaseAsset>{};
  ReleaseAsset? universalAsset;

  for (final asset in release.assets) {
    if (!asset.isAndroidApk) {
      continue;
    }
    final abi = asset.androidAbi;
    if (abi == null || abi.isEmpty) {
      universalAsset ??= asset;
      continue;
    }
    abiAssetMap.putIfAbsent(abi, () => asset);
  }

  for (final abi in supportedAbis) {
    final asset = abiAssetMap[abi];
    if (asset != null) {
      return AndroidReleaseAsset(
        apkAsset: asset,
        abi: abi,
        checksumAsset: release.findSha256AssetFor(asset),
      );
    }
  }

  if (universalAsset != null) {
    return AndroidReleaseAsset(
      apkAsset: universalAsset,
      abi: 'universal',
      checksumAsset: release.findSha256AssetFor(universalAsset),
    );
  }
  return null;
}

String? parseSha256Content(
  String? content, {
  String? assetName,
}) {
  if (content == null || content.trim().isEmpty) {
    return null;
  }
  final normalizedAssetName = assetName?.trim();
  String? fallbackHash;
  var sawNamedEntry = false;
  for (final rawLine in content.split('\n')) {
    final entry = _parseSha256Line(rawLine);
    if (entry == null) {
      continue;
    }
    if (normalizedAssetName == null) {
      return entry.hash;
    }
    if (entry.assetName == null) {
      fallbackHash ??= entry.hash;
      continue;
    }
    sawNamedEntry = true;
    if (_matchesSha256AssetName(entry.assetName!, normalizedAssetName)) {
      return entry.hash;
    }
  }
  if (sawNamedEntry) {
    return null;
  }
  return fallbackHash;
}

Future<String> computeFileSha256(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

AppRelease? selectLatestStableRelease(Iterable<AppRelease> releases) {
  return selectLatestAppRelease(
    releases,
    includePrerelease: false,
  );
}

AppRelease? selectLatestAppRelease(
  Iterable<AppRelease> releases, {
  required bool includePrerelease,
}) {
  AppRelease? latestRelease;
  for (final release in releases) {
    if (release.draft || (!includePrerelease && release.prerelease)) {
      continue;
    }
    if (latestRelease == null ||
        utils.compareVersions(release.version, latestRelease.version) > 0) {
      latestRelease = release;
    }
  }
  return latestRelease;
}

_ParsedSha256Line? _parseSha256Line(String rawLine) {
  final line = rawLine.trim();
  if (line.isEmpty) {
    return null;
  }

  final hashFirstMatch = RegExp(
    r'^([a-fA-F0-9]{64})\s+[*]?(.+)$',
  ).firstMatch(line);
  if (hashFirstMatch != null) {
    return _ParsedSha256Line(
      hash: hashFirstMatch.group(1)!.toLowerCase(),
      assetName: hashFirstMatch.group(2)!.trim(),
    );
  }

  final sha256sumStyleMatch = RegExp(
    r'^SHA256\s+\((.+)\)\s*=\s*([a-fA-F0-9]{64})$',
    caseSensitive: false,
  ).firstMatch(line);
  if (sha256sumStyleMatch != null) {
    return _ParsedSha256Line(
      hash: sha256sumStyleMatch.group(2)!.toLowerCase(),
      assetName: sha256sumStyleMatch.group(1)!.trim(),
    );
  }

  final digestOnlyMatch = RegExp(
    r'^(?:sha256:)?([a-fA-F0-9]{64})$',
    caseSensitive: false,
  ).firstMatch(line);
  if (digestOnlyMatch != null) {
    return _ParsedSha256Line(
      hash: digestOnlyMatch.group(1)!.toLowerCase(),
    );
  }

  return null;
}

bool _matchesSha256AssetName(String rawAssetName, String expectedAssetName) {
  final candidate = rawAssetName.trim();
  if (candidate == expectedAssetName) {
    return true;
  }
  final segments = candidate.split(RegExp(r'[\\/]'));
  return segments.isNotEmpty && segments.last == expectedAssetName;
}

class _ParsedSha256Line {
  const _ParsedSha256Line({
    required this.hash,
    this.assetName,
  });

  final String hash;
  final String? assetName;
}
