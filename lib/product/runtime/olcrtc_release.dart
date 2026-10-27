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
    sha256: 'bc67aa97d0f4389306f2f3f4eba50b5693ab82f4c9276630ae5cbdf26f2fe363',
  ),
  'arm64-v8a': OlcRtcReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    goArch: 'arm64',
    sha256: 'a9a6683be44ba010f90106880d2098195001842737359185cfa9f3fc355f59d5',
  ),
  'x86_64': OlcRtcReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    goArch: 'amd64',
    sha256: '48a23ad0b0726737447328276f630d722d7b71ba81bbb6cf76120e907fdd47d5',
  ),
};
