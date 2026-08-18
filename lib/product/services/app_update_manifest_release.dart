import 'app_update_manifest.dart';
import 'app_update_release.dart';

extension AppUpdateManifestReleaseMapping on AppUpdateManifest {
  AppRelease toRelease() => AppRelease(
        tagName: tagName,
        body: body,
        htmlUrl: htmlUrl,
        assets: assets.map((asset) => asset.toReleaseAsset()).toList(),
        prerelease: channel == AppUpdateChannel.prerelease,
        draft: false,
        versionCode: versionCode,
      );
}

extension AppUpdateManifestAssetReleaseMapping on AppUpdateManifestAsset {
  ReleaseAsset toReleaseAsset() => ReleaseAsset(
        name: name,
        browserDownloadUrl: urls.first,
        downloadUrls: urls,
        size: size,
        digest: 'sha256:$sha256',
      );
}
