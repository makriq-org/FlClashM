const naiveProxyPinnedReleaseTag = 'v154.0.8037.49-5';
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
    apkName: 'naiveproxy-plugin-v154.0.8037.49-5-armeabi-v7a.apk',
    apkSha256:
        '9acbf08afea2d35aad492d5312444b6aecd5fafa41f29d794d4821549f330da5',
  ),
  'arm64-v8a': NaiveProxyReleaseAsset(
    abi: 'arm64-v8a',
    apkName: 'naiveproxy-plugin-v154.0.8037.49-5-arm64-v8a.apk',
    apkSha256:
        '3a532e6894d87c1fca5c527d3598892627829c76cb5b75ed831555f384841bd0',
  ),
  'x86_64': NaiveProxyReleaseAsset(
    abi: 'x86_64',
    apkName: 'naiveproxy-plugin-v154.0.8037.49-5-x86_64.apk',
    apkSha256:
        'af3e8070e882f0008b6511394ae4d3737ece508e9b34abee94cb2f59ddb5e940',
  ),
};
