const qwdttPinnedCommit = 'd750e580e756dbe3d6dddddd58513a5d91a6ed6e';
const qwdttPinnedReleaseTag = 'flclashm-qwdtt-1';
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
    sha256: 'f6440bb3acab739684171f905b048bdbb83c35cc43282bddcb482f8c7b665ece',
  ),
  'arm64-v8a': QwdttReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    goArch: 'arm64',
    sha256: '149e702293ce706be3552f40364bd4ac2e201a1976248a9a83ac5cb98008e33e',
  ),
  'x86_64': QwdttReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    goArch: 'amd64',
    sha256: '87a6e23519d77cc27902fba552966a84c58ee10590b8160745b409af0884ecc2',
  ),
};
