const stormDnsPinnedCommit = '87348df5b11f9e490262a713ca268734007af44f';
const stormDnsPinnedReleaseTag = 'git-$stormDnsPinnedCommit';
const stormDnsPinnedGoVersion = 'go1.26.4';
const stormDnsPinnedNdkVersion = '28.0.13004108';
const stormDnsSourceRepository = 'https://github.com/nullroute1970/StormDNS.git';
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
    sha256: 'c4827e10919f6996948bf2fa36c1e125156d8196e23d8abcdd590678d94eb839',
  ),
  'arm64-v8a': StormDnsReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    goArch: 'arm64',
    sha256: '95b77cedd2411d3195abefbdf3c946b7e72ef25ee08e18d73e4f03b33f6b3f01',
  ),
  'x86_64': StormDnsReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    goArch: 'amd64',
    sha256: '96c5f69049872ce1008e4801bac7930b9d740b23c9cc05275f45bdafed0137ab',
  ),
};
