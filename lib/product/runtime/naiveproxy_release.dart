const naiveProxyPinnedReleaseTag = 'v150.0.7871.63-1';
const naiveProxyBundledAssetRoot = 'assets/runtimes/naiveproxy/android';
const naiveProxyRuntimeArtifactConfigPath = 'naiveproxy/config.json';
const naiveProxyRuntimeDirectoryName = 'naiveproxy';
const naiveProxyExecutableFileName = 'naiveproxy';
const naiveProxyAndroidNativeLibraryFileName = 'libflclashm_naiveproxy.so';
const naiveProxyConfigFileName = 'config.json';
const naiveProxyDefaultListenerPort = 7891;
const naiveProxyBridgeProxyName = 'naiveproxy-local';
const naiveProxyBridgeGroupName = 'GLOBAL';

class NaiveProxyReleaseAsset {
  const NaiveProxyReleaseAsset({
    required this.abi,
    required this.apkName,
    required this.apkSha256,
  });

  final String abi;
  final String apkName;
  final String apkSha256;

  String get bundledAssetPath => '$naiveProxyBundledAssetRoot/$abi/libnaive.so';

  String get downloadUrl =>
      'https://github.com/klzgrad/naiveproxy/releases/download/'
      '$naiveProxyPinnedReleaseTag/$apkName';
}

const naiveProxyReleaseAssets = <String, NaiveProxyReleaseAsset>{
  'armeabi-v7a': NaiveProxyReleaseAsset(
    abi: 'armeabi-v7a',
    apkName: 'naiveproxy-plugin-v150.0.7871.63-1-armeabi-v7a.apk',
    apkSha256:
        'd52b01d0a55cd0807fe196e72abd5aa4859a783798b1bc1b3cf1bfa9ad8f7ae4',
  ),
  'arm64-v8a': NaiveProxyReleaseAsset(
    abi: 'arm64-v8a',
    apkName: 'naiveproxy-plugin-v150.0.7871.63-1-arm64-v8a.apk',
    apkSha256:
        '733fbbbebb383a91f42036992c21cfd19b99e089ac3d15d7c077df79fc471a89',
  ),
  'x86_64': NaiveProxyReleaseAsset(
    abi: 'x86_64',
    apkName: 'naiveproxy-plugin-v150.0.7871.63-1-x86_64.apk',
    apkSha256:
        'a6800d30bb70798d7b9ad3d0218469c58776c250b462926a7cc2e7795d915f78',
  ),
};
