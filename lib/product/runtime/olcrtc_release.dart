const olcRtcPinnedCommit = '2a5153529b0496fe8b42929c56f8cb2e7d36c917';
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
    sha256: 'c5422c3ced7f29efede8e655dd75a8ceb35517409762e50f62fde0888d20e17e',
  ),
  'arm64-v8a': OlcRtcReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    goArch: 'arm64',
    sha256: 'd77b6fe9710bdd920c6399283e24495b2f994cf269b27f1e39eaeb84d167d47c',
  ),
  'x86_64': OlcRtcReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    goArch: 'amd64',
    sha256: 'c3763e36faa7cdd27f89e0f82e281242696a5f3d458ff486558abae93800097e',
  ),
};
