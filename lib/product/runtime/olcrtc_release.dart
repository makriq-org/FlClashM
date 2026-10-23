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
    sha256: '647630defdc352937599aa2f02d7eabef7d0c958b60234eafcac9517c244489f',
  ),
  'arm64-v8a': OlcRtcReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    goArch: 'arm64',
    sha256: 'd2540f20a9cfdf78c2ecf852d3fca32e0adf9c478850b0635e0d99365ebfef5d',
  ),
  'x86_64': OlcRtcReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    goArch: 'amd64',
    sha256: '0620f0789727400703266788b6c4c9143cf51e10724ceccc1b46023a7f98f1c8',
  ),
};
