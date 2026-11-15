const byedpiPinnedCommit = 'e2684772fbda45f2ff4fc220922a010370534216';
const byedpiPinnedReleaseTag = 'git-$byedpiPinnedCommit';
const byedpiSourceRepository = 'https://github.com/hufrea/byedpi.git';
const byedpiBundledAssetRoot = 'assets/runtimes/byedpi/android';
const byedpiRuntimeDirectoryName = 'byedpi';
const byedpiExecutableFileName = 'ciadpi';
const byedpiAndroidNativeLibraryFileName = 'libflclashm_byedpi.so';
const byedpiConfigFileName = 'config.json';

class ByedpiReleaseAsset {
  const ByedpiReleaseAsset({
    required this.abi,
    required this.cliArch,
    required this.sha256,
  });

  final String abi;
  final String cliArch;
  final String sha256;

  String get bundledAssetPath => '$byedpiBundledAssetRoot/$abi/ciadpi.bin';
}

const byedpiReleaseAssets = <String, ByedpiReleaseAsset>{
  'armeabi-v7a': ByedpiReleaseAsset(
    abi: 'armeabi-v7a',
    cliArch: 'arm',
    sha256: 'ee10fb1b1739cba04fcbbfbd5193f8f6cc9ca71ad057f397e40753682a2dade0',
  ),
  'arm64-v8a': ByedpiReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    sha256: '385e8c267b935de14b10e4313e8cf934d808c7cd7c0a865690c40e4baefaef2c',
  ),
  'x86_64': ByedpiReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    sha256: '3e960a8dae765305be467f7c4ab27f0434220b8bedf5c8afc0c613bf547cf7f4',
  ),
};
