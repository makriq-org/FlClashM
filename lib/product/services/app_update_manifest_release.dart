import 'app_update_manifest.dart';
import 'app_update_release.dart';

extension AppUpdateManifestReleaseMapping on AppUpdateManifest {
  /// [now] решает, свежий ли каталог: минимальная версия из старого каталога
  /// не переезжает в предложение об обновлении.
  AppRelease toRelease({DateTime? now}) {
    final fresh = isFreshAt(now ?? DateTime.now());
    return AppRelease(
      tagName: tagName,
      body: body,
      htmlUrl: htmlUrl,
      assets: assets.map((asset) => asset.toReleaseAsset()).toList(),
      prerelease: channel == AppUpdateChannel.prerelease,
      draft: false,
      versionCode: versionCode,
      minimumVersion: fresh ? minimumVersion : null,
      minimumVersionCode: fresh ? minimumVersionCode : null,
    );
  }
}

extension AppUpdateManifestAssetReleaseMapping on AppUpdateManifestAsset {
  ReleaseAsset toReleaseAsset() => ReleaseAsset(
    name: name,
    browserDownloadUrl: urls.first,
    downloadUrls: urls,
    size: size,
    digest: 'sha256:$sha256',
    versionCode: versionCode,
  );
}
