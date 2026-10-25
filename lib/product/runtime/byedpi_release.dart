const byedpiPinnedCommit = 'ba532298de7b28cfe854aea83d061369d13ca290';
const byedpiPinnedReleaseTag = 'git-$byedpiPinnedCommit';
const byedpiSourceRepository = 'https://github.com/hufrea/byedpi.git';
const byedpiStrategySourceRepository =
    'https://github.com/romanvht/ByeByeDPI.git';
const byedpiStrategyPinnedCommit = '96a3c1ff555043d915af814aa4f0e9a572c89aba';
const byedpiBundledAssetRoot = 'assets/runtimes/byedpi/android';
const byedpiRuntimeDirectoryName = 'byedpi';
const byedpiExecutableFileName = 'ciadpi';
const byedpiAndroidNativeLibraryFileName = 'libflclashm_byedpi.so';
const byedpiConfigFileName = 'config.json';
const byedpiStrategyListAssetPath =
    '$byedpiBundledAssetRoot/byebyeedpi-strategies.list';

class ByedpiReleaseAsset {
  const ByedpiReleaseAsset({required this.abi, required this.cliArch});

  final String abi;
  final String cliArch;

  String get bundledAssetPath => '$byedpiBundledAssetRoot/$abi/ciadpi.bin';
}

const byedpiReleaseAssets = <String, ByedpiReleaseAsset>{
  'armeabi-v7a': ByedpiReleaseAsset(abi: 'armeabi-v7a', cliArch: 'arm'),
  'arm64-v8a': ByedpiReleaseAsset(abi: 'arm64-v8a', cliArch: 'arm64'),
  'x86_64': ByedpiReleaseAsset(abi: 'x86_64', cliArch: 'amd64'),
};
