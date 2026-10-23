const olcRtcPinnedCommit = 'b2c4b17ee35bfe65330aa9141f94dac082228bb2';
const olcRtcPinnedReleaseTag = 'git-$olcRtcPinnedCommit';
const olcRtcPinnedGoVersion = 'go1.27.2';
const olcRtcPinnedNdkVersion = '28.0.13004108';
const olcRtcSourceRepository =
    'https://github.com/ghostlane-project/olcrtc.git';
const olcRtcBundledAssetRoot = 'assets/runtimes/olcrtc/android';
const olcRtcRuntimeDirectoryName = 'olcrtc';
const olcRtcExecutableFileName = 'olcrtc';
const olcRtcAndroidNativeLibraryFileName = 'libflclashm_olcrtc.so';
const olcRtcConfigTemplateFileName = 'config.template.yaml';
const olcRtcSystemDnsPlaceholder = '@flclashm-system-dns@';
const olcRtcConfigFileName = 'config.yaml';

class OlcRtcReleaseAsset {
  const OlcRtcReleaseAsset({
    required this.abi,
    required this.cliArch,
    required this.goArch,
    required this.sha256,
    this.goArm,
  });

  final String abi;
  final String cliArch;
  final String goArch;
  final String sha256;
  final String? goArm;

  String get bundledAssetPath => '$olcRtcBundledAssetRoot/$abi/olcrtc.bin';
}

const olcRtcReleaseAssets = <String, OlcRtcReleaseAsset>{
  'armeabi-v7a': OlcRtcReleaseAsset(
    abi: 'armeabi-v7a',
    cliArch: 'arm',
    goArch: 'arm',
    goArm: '7',
    sha256: '07f3e14109c0d2aae37e2c9b1cbb08af0f7707b26346231b233a192fd127db16',
  ),
  'arm64-v8a': OlcRtcReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    goArch: 'arm64',
    sha256: '07063a74e697613eacfb3172565c213a0af83720f345a783321657e848bfb072',
  ),
  'x86_64': OlcRtcReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    goArch: 'amd64',
    sha256: '746ca09065d10e283efd584d781bdf6e8050dc9734131e9367d26a2d062ef65d',
  ),
};
