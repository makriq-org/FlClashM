const stormDnsPinnedCommit = 'ca2eb481fddd4a80d26b3a1a7c714b5aecacecfc';
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
    sha256: '64d0073dc5a6d5eca1230611cdeec0141638eb2bd7dba762c40ddb06dcd17bd7',
  ),
  'arm64-v8a': StormDnsReleaseAsset(
    abi: 'arm64-v8a',
    cliArch: 'arm64',
    goArch: 'arm64',
    sha256: 'b330ef9c4dc175ae1ec5cdff4dced413639102f0a0705d47ea5907ec08b5bf62',
  ),
  'x86_64': StormDnsReleaseAsset(
    abi: 'x86_64',
    cliArch: 'amd64',
    goArch: 'amd64',
    sha256: '32ad47d5709f16dd58cd267926346c066eb1e5ae319c34d6957a68dfbc6564e3',
  ),
};
