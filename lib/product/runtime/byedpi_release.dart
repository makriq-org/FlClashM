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
    sha256: '7b0103436e67bc98a1a767ba815cae1ff59c6ccd4d855c5b063776ce10aa6b80',
  ),
  'arm64-v8a': ByedpiReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    sha256: '40da1939a5d71a14b0a45bf516ad474d69e3703169e30706039cf8ee7601231a',
  ),
  'x86_64': ByedpiReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    sha256: 'e0cfa92b43247061024d85e58802e6411858eb02e4fce7a148fe4dd3762101f0',
  ),
};
