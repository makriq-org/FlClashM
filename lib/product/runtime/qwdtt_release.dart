const qwdttPinnedCommit = 'ba5281273b43250ca5b756e31f73232bd9702f38';
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
    sha256: '6a9709b122545a5d75ca6bba479b654e31050844a6f325a61ed9569e6aeff829',
  ),
  'arm64-v8a': QwdttReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    goArch: 'arm64',
    sha256: '5c5864fdf7d3d29e47a8017c6cda1d1c9715ce8cf69aca59113f16cdd383b1f9',
  ),
  'x86_64': QwdttReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    goArch: 'amd64',
    sha256: '283959f2f8c07134b7b6bd9a3b724a449e73dab462f2a4bed435695912c1d36a',
  ),
};
