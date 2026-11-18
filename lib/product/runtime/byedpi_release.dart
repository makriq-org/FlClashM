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
    sha256: 'bcdbcf546031d55e4a521037522eb0a95e83954685b234aae905e6ec4fd89bee',
  ),
  'arm64-v8a': ByedpiReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    sha256: '9e1a8ad2e07f210d33018d26327a69c918b192fa8c7a34cd8669f6d0cf261924',
  ),
  'x86_64': ByedpiReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    sha256: '65e55bb2afbe4cbe4ebba0f59d03356a648042d9d20f6dafc86b6ad6057a9893',
  ),
};
