const qwdttPinnedCommit = '4695bbebf00e9d4bc5cf16117dc4db236ae50158';
const qwdttPinnedReleaseTag = 'git-$qwdttPinnedCommit';
const qwdttPinnedGoVersion = 'go1.27.3';
const qwdttPinnedNdkVersion = '28.0.13004108';
const qwdttSourceRepository = 'https://github.com/makriq-org/qwdtt.git';
const qwdttBundledAssetRoot = 'assets/runtimes/qwdtt/android';
const qwdttRuntimeDirectoryName = 'qwdtt';
const qwdttExecutableFileName = 'qwdtt';
const qwdttAndroidNativeLibraryFileName = 'libflclashm_qwdtt.so';
const qwdttConfigFileName = 'config.json';

class QwdttReleaseAsset {
  const QwdttReleaseAsset({
    required this.abi,
    required this.cliArch,
    required this.goArch,
    required this.sha256,
    this.goArm,
  });

  final String abi;
  final String cliArch;
  final String goArch;
  final String? goArm;
  final String sha256;

  String get bundledAssetPath => '$qwdttBundledAssetRoot/$abi/qwdtt.bin';
}

const qwdttReleaseAssets = <String, QwdttReleaseAsset>{
  'armeabi-v7a': QwdttReleaseAsset(
    abi: 'armeabi-v7a',
    cliArch: 'arm',
    goArch: 'arm',
    goArm: '7',
    sha256: '2aad8db51735f84576e53282afc2ee1eb3fe75190780962738535976f16ac086',
  ),
  'arm64-v8a': QwdttReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    goArch: 'arm64',
    sha256: '609ff14937f175cd8b3f3a2af0eed72c7194467a20f6eb1ed04c9aedb04cc8b9',
  ),
  'x86_64': QwdttReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    goArch: 'amd64',
    sha256: 'e3400f9f9ed12f8ee542363a39c9cb93fad29cfdf135723d968dfe433859b63c',
  ),
};
