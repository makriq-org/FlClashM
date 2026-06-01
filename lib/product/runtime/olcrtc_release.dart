const olcRtcPinnedCommit = '5dd6822d807e3352fe4452a3b071e043d958a020';
const olcRtcPinnedReleaseTag = 'git-$olcRtcPinnedCommit';
const olcRtcSourceRepository =
    'https://github.com/openlibrecommunity/olcrtc.git';
const olcRtcBundledAssetRoot = 'assets/runtimes/olcrtc/android';
const olcRtcRuntimeDirectoryName = 'olcrtc';
const olcRtcExecutableFileName = 'olcrtc';
const olcRtcBundledVersionFileName = 'bundled.version';
const olcRtcPendingVersionFileName = 'bundled.pending.version';
const olcRtcConfigFileName = 'config.yaml';

class OlcRtcReleaseAsset {
  const OlcRtcReleaseAsset({
    required this.abi,
    required this.cliArch,
    required this.goArch,
    this.goArm,
  });

  final String abi;
  final String cliArch;
  final String goArch;
  final String? goArm;

  String get bundledAssetPath => '$olcRtcBundledAssetRoot/$abi/olcrtc';
}

const olcRtcReleaseAssets = <String, OlcRtcReleaseAsset>{
  'armeabi-v7a': OlcRtcReleaseAsset(
    abi: 'armeabi-v7a',
    cliArch: 'arm',
    goArch: 'arm',
    goArm: '7',
  ),
  'arm64-v8a': OlcRtcReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    goArch: 'arm64',
  ),
  'x86_64': OlcRtcReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    goArch: 'amd64',
  ),
};
