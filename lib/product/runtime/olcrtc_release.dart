const olcRtcPinnedCommit = 'b2c4b17ee35bfe65330aa9141f94dac082228bb2';
const olcRtcPinnedReleaseTag = 'git-$olcRtcPinnedCommit';
const olcRtcPinnedGoVersion = 'go1.27.3';
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
    sha256: '3e634c4b640c69de1724b7a359e0cb6c56b1d3bb9c26f5f54e63c2cf01dfe75c',
  ),
  'arm64-v8a': OlcRtcReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    goArch: 'arm64',
    sha256: 'b8ea3b66920f42c9f6cca898adaada1e71515ebe020df57124abba678c45b86e',
  ),
  'x86_64': OlcRtcReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    goArch: 'amd64',
    sha256: '32e03410dd7a13d124008cd8b1c830b9ce24a365c396084e86f6b4d8b9dfd226',
  ),
};
