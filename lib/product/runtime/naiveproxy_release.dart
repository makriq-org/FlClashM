const naiveProxyPinnedReleaseTag = 'v148.0.7778.96-5';
const naiveProxyBundledAssetRoot = 'assets/runtimes/naiveproxy/android';
const naiveProxyRuntimeArtifactConfigPath = 'naiveproxy/config.json';
const naiveProxyRuntimeDirectoryName = 'naiveproxy';
const naiveProxyExecutableFileName = 'naiveproxy';
const naiveProxyBundledVersionFileName = 'bundled.version';
const naiveProxyPendingVersionFileName = 'bundled.pending.version';
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
    apkName: 'naiveproxy-plugin-v148.0.7778.96-5-armeabi-v7a.apk',
    apkSha256:
        'b09efbdbcd0735f9db625876e4eddef3187d92174c5df3df416c0bd78e7293bc',
  ),
  'arm64-v8a': NaiveProxyReleaseAsset(
    abi: 'arm64-v8a',
    apkName: 'naiveproxy-plugin-v148.0.7778.96-5-arm64-v8a.apk',
    apkSha256:
        '38bafaec595aedec70c0e7f1cfca68aae12adaf702abf7951e9a6e36a76ac34f',
  ),
  'x86_64': NaiveProxyReleaseAsset(
    abi: 'x86_64',
    apkName: 'naiveproxy-plugin-v148.0.7778.96-5-x86_64.apk',
    apkSha256:
        '25a0c820a3fd8ab74dafe87a9fbcc8971f44eac62f46b6771fca2151b816a855',
  ),
};
