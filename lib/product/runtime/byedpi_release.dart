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
    sha256: 'd4a32e79603b5fc55a6c2479b567ac6ce743387b3f67e24e27c7a705b2ad3210',
  ),
  'arm64-v8a': ByedpiReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    sha256: 'a8ae867d6f35fe8e5ff72aaa6b5873aa897c6930ea9776eea886372efa47a161',
  ),
  'x86_64': ByedpiReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    sha256: '9ff97b6f826c2127ced0511adaf69857f029edca90d51c9fb8994964b57fb87e',
  ),
};
