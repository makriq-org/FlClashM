const stormDnsPinnedCommit = 'a9a8e92a51f08c3030d7a1656cafd3bf07c9903b';
const stormDnsPinnedReleaseTag = 'git-$stormDnsPinnedCommit';
const stormDnsPinnedGoVersion = 'go1.27.2';
const stormDnsPinnedNdkVersion = '28.0.13004108';
const stormDnsSourceRepository =
    'https://github.com/nullroute1970/StormDNS.git';
const stormDnsBundledAssetRoot = 'assets/runtimes/stormdns/android';
const stormDnsRuntimeDirectoryName = 'stormdns';
const stormDnsExecutableFileName = 'stormdns';
const stormDnsAndroidNativeLibraryFileName = 'libflclashm_stormdns.so';

/// TOML client config staged into every node working directory.
const stormDnsConfigFileName = 'client_config.toml';

/// Resolver list StormDNS actually reads, one resolver per line.
///
/// The platform generates it from [stormDnsResolversTemplateFileName] and
/// rewrites it whenever the physical network DNS changes, so it must stay
/// inside the node working directory.
const stormDnsResolversFileName = 'client_resolvers.txt';

/// Resolver list template staged by the profile compiler.
///
/// Keeping the template separate from the generated file means a platform
/// rewrite never looks like a profile change, so nodes are not restarted on
/// every profile apply.
const stormDnsResolversTemplateFileName = 'client_resolvers.template';

/// Directory (relative to the node working directory) that holds the StormDNS
/// resolver cache log. The app owns this path; users cannot move it.
const stormDnsLogDirectoryName = 'logs';

/// Working-cache directory holding the MTU/resolver cache for one fingerprint.
const stormDnsCacheDirectoryName = 'cache';

class StormDnsReleaseAsset {
  const StormDnsReleaseAsset({
    required this.abi,
    required this.cliArch,
    required this.goArch,
    required this.sha256,
    this.goArm,
  });

  final String abi;
  final String cliArch;
  final String goArch;
  final String sha256;
  final String? goArm;

  String get bundledAssetPath => '$stormDnsBundledAssetRoot/$abi/stormdns.bin';
}

const stormDnsReleaseAssets = <String, StormDnsReleaseAsset>{
  'armeabi-v7a': StormDnsReleaseAsset(
    abi: 'armeabi-v7a',
    cliArch: 'arm',
    goArch: 'arm',
    goArm: '7',
    sha256: '00d6a9ce4252f5f8364344c99352780339271332869875a0b845137cd31fdfa3',
  ),
  'arm64-v8a': StormDnsReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    goArch: 'arm64',
    sha256: 'aa552f8dd559bb6e7194680e9fc798bc827ad4e3660c6cef8a873c3aff7be2fc',
  ),
  'x86_64': StormDnsReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    goArch: 'amd64',
    sha256: '76848368161b2aade8101bf0f284027b85b88ac9f983ce695d69cdc93bf1eab9',
  ),
};
