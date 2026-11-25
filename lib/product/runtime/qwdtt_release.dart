const qwdttPinnedCommit = '3621143480bfff8aa63f5201a1da977f07fc47ed';
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
    sha256: 'd3ade2cdde8ba7804506e29c4eaf3453c8810e7ba32246b970299ad407c84933',
  ),
  'arm64-v8a': QwdttReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    goArch: 'arm64',
    sha256: 'baf93e506b635f07935d57b5d7dd78667dd0d16be391be533e37e0c541cde6c2',
  ),
  'x86_64': QwdttReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    goArch: 'amd64',
    sha256: '8aa5d56116b0c8fc760a4a89b9c14b7fca809137cf4487e0bf527df9424e0fb4',
  ),
};
