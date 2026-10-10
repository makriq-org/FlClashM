const naiveProxyPinnedReleaseTag = 'v154.0.8037.49-4';
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
    apkName: 'naiveproxy-plugin-v154.0.8037.49-4-armeabi-v7a.apk',
    apkSha256:
        '175e0edcccf65c9e69ff9b2b3185b86474008d14c5ed7507bbb63a4bf3765797',
  ),
  'arm64-v8a': NaiveProxyReleaseAsset(
    abi: 'arm64-v8a',
    apkName: 'naiveproxy-plugin-v154.0.8037.49-4-arm64-v8a.apk',
    apkSha256:
        '53d2ffd05fa13a8af22225bd738e5f59c7a499b369917c633a30c19c84f1f117',
  ),
  'x86_64': NaiveProxyReleaseAsset(
    abi: 'x86_64',
    apkName: 'naiveproxy-plugin-v154.0.8037.49-4-x86_64.apk',
    apkSha256:
        'afc8a46604e1af7675bc6aa9ae22dee8fcd8c731d7daade17e7361db5daffb71',
  ),
};
