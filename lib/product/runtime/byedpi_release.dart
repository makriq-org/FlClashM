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
    sha256: 'a93cedec077e9f20882e1f156e3e60f6b5254eb3d17eb70dcb7f6134b91ae956',
  ),
  'arm64-v8a': ByedpiReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    sha256: '1f293f0fcad6d945296a29ab87966fac9d4712a370ef5b934927e0a6d8f7c00b',
  ),
  'x86_64': ByedpiReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    sha256: '04d306f13ef80d0c37f70cabc376542dd000ecbb922e465b088d570f800b78dc',
  ),
};
