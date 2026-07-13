import 'package:device_info_plus/device_info_plus.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'built_in_proxy_types.dart';
import 'local_node_controller.dart';
import 'naiveproxy_release.dart';

@immutable
class NaiveProxySharedInstallLayout extends LocalNodeSharedInstallLayout {
  const NaiveProxySharedInstallLayout({
    required super.abi,
    required super.runtimeRootPath,
    required super.nodesDirectoryPath,
    required super.executablePath,
  });
}

@immutable
class NaiveProxyNodeLayout extends LocalNodeLayout {
  const NaiveProxyNodeLayout({
    required super.nodeId,
    required super.workingDirectoryPath,
    required super.configPath,
  });
}

abstract interface class NaiveProxyBinaryBridge
    extends LocalNodeBinaryBridge<NaiveProxySharedInstallLayout> {}

class DefaultNaiveProxyBinaryBridge implements NaiveProxyBinaryBridge {
  const DefaultNaiveProxyBinaryBridge({
    this.nativeLibrary = const AndroidRuntimeNodeNativeLibraryBridge(),
  });

  final AndroidRuntimeNodeNativeLibraryBridge nativeLibrary;

  @override
  Future<NaiveProxySharedInstallLayout> resolveSharedInstallLayout() async {
    final deviceInfo = await DeviceInfoPlugin().androidInfo;
    NaiveProxyReleaseAsset? asset;
    for (final abi in deviceInfo.supportedAbis) {
      final candidate = naiveProxyReleaseAssets[abi];
      if (candidate != null) {
        asset = candidate;
        break;
      }
    }
    if (asset == null) {
      throw UnsupportedError(
        'naiveproxy is not packaged for Android ABIs: '
        '${deviceInfo.supportedAbis.join(', ')}',
      );
    }

    final homeDir = await appPath.homeDirPath;
    final runtimeRootPath = path.join(
      homeDir,
      'runtimes',
      naiveProxyRuntimeDirectoryName,
      asset.abi,
    );
    final executablePath = await nativeLibrary.resolvePath(
      naiveProxyAndroidNativeLibraryFileName,
    );
    if (executablePath == null) {
      throw StateError(
        'Bundled native naiveproxy library '
        '$naiveProxyAndroidNativeLibraryFileName is missing. '
        'Run `dart setup.dart android --out runtime-assets` before building.',
      );
    }

    return NaiveProxySharedInstallLayout(
      abi: asset.abi,
      runtimeRootPath: runtimeRootPath,
      nodesDirectoryPath: path.join(runtimeRootPath, 'nodes'),
      executablePath: executablePath,
    );
  }
}

class NaiveProxyNodeController extends LocalNodeController<
    NaiveProxySharedInstallLayout, NaiveProxyNodeLayout> {
  NaiveProxyNodeController({
    NaiveProxyBinaryBridge binary = const DefaultNaiveProxyBinaryBridge(),
    super.runtime = const AndroidRuntimeNodeBridge(),
  }) : super(
          typeLabel: 'naiveproxy',
          configArtifactName: 'config.json',
          binary: binary,
        );

  @override
  String readConfigArtifact(BuiltInProxyNodePlan plan) {
    final configJson =
        plan.files['built-in-proxies/naiveproxy/${plan.nodeId}/config.json'];
    if (configJson == null || configJson.isEmpty) {
      throw StateError(
        'naiveproxy node `${plan.name}` is missing config.json artifact.',
      );
    }
    return configJson;
  }

  @override
  NaiveProxyNodeLayout resolveNodeLayout(
    NaiveProxySharedInstallLayout sharedLayout,
    String nodeId,
  ) {
    final workingDirectoryPath =
        path.join(sharedLayout.nodesDirectoryPath, nodeId);
    return NaiveProxyNodeLayout(
      nodeId: nodeId,
      workingDirectoryPath: workingDirectoryPath,
      configPath: path.join(workingDirectoryPath, naiveProxyConfigFileName),
    );
  }
}
