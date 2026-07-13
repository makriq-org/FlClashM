import 'package:device_info_plus/device_info_plus.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'built_in_proxy_types.dart';
import 'local_node_controller.dart';
import 'olcrtc_release.dart';

@immutable
class OlcRtcSharedInstallLayout extends LocalNodeSharedInstallLayout {
  const OlcRtcSharedInstallLayout({
    required super.abi,
    required super.runtimeRootPath,
    required super.nodesDirectoryPath,
    required super.executablePath,
    required super.pendingPath,
    required super.rollbackPath,
    required super.versionPath,
    required super.pendingVersionPath,
    required super.bundledAssetPath,
    super.managedBinaryUpdateEnabled = true,
  });
}

@immutable
class OlcRtcNodeLayout extends LocalNodeLayout {
  const OlcRtcNodeLayout({
    required super.nodeId,
    required super.workingDirectoryPath,
    required super.configPath,
  });
}

abstract interface class OlcRtcBinaryBridge
    extends LocalNodeBinaryBridge<OlcRtcSharedInstallLayout> {}

class DefaultOlcRtcBinaryBridge implements OlcRtcBinaryBridge {
  const DefaultOlcRtcBinaryBridge({
    this.nativeLibrary = const AndroidRuntimeNodeNativeLibraryBridge(),
  });

  final AndroidRuntimeNodeNativeLibraryBridge nativeLibrary;

  @override
  String get bundledReleaseTag => olcRtcPinnedReleaseTag;

  @override
  Future<OlcRtcSharedInstallLayout> resolveSharedInstallLayout() async {
    final deviceInfo = await DeviceInfoPlugin().androidInfo;
    OlcRtcReleaseAsset? asset;
    for (final abi in deviceInfo.supportedAbis) {
      final candidate = olcRtcReleaseAssets[abi];
      if (candidate != null) {
        asset = candidate;
        break;
      }
    }
    if (asset == null) {
      throw UnsupportedError(
        'olcrtc is not packaged for Android ABIs: '
        '${deviceInfo.supportedAbis.join(', ')}',
      );
    }

    final homeDir = await appPath.homeDirPath;
    final runtimeRootPath = path.join(
      homeDir,
      'runtimes',
      olcRtcRuntimeDirectoryName,
      asset.abi,
    );
    final executablePath = await nativeLibrary.resolvePath(
      olcRtcAndroidNativeLibraryFileName,
    );
    if (executablePath == null) {
      throw StateError(
        'Bundled native olcrtc library $olcRtcAndroidNativeLibraryFileName '
        'is missing. Run `dart setup.dart android --out runtime-assets` '
        'before building.',
      );
    }

    return OlcRtcSharedInstallLayout(
      abi: asset.abi,
      runtimeRootPath: runtimeRootPath,
      nodesDirectoryPath: path.join(runtimeRootPath, 'nodes'),
      executablePath: executablePath,
      pendingPath: path.join(
        runtimeRootPath,
        '$olcRtcExecutableFileName.pending',
      ),
      rollbackPath: path.join(
        runtimeRootPath,
        '$olcRtcExecutableFileName.rollback',
      ),
      versionPath: path.join(
        runtimeRootPath,
        olcRtcBundledVersionFileName,
      ),
      pendingVersionPath: path.join(
        runtimeRootPath,
        olcRtcPendingVersionFileName,
      ),
      bundledAssetPath: asset.bundledAssetPath,
      managedBinaryUpdateEnabled: false,
    );
  }

  @override
  Future<Uint8List> loadBundledBinary(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    return data.buffer.asUint8List();
  }
}

class OlcRtcNodeController
    extends LocalNodeController<OlcRtcSharedInstallLayout, OlcRtcNodeLayout> {
  OlcRtcNodeController({
    OlcRtcBinaryBridge binary = const DefaultOlcRtcBinaryBridge(),
    super.runtime = const AndroidRuntimeNodeBridge(),
    super.waitForListener = waitForLocalNodeListener,
    super.connectivityChecker,
  }) : super(
          typeLabel: 'olcrtc',
          configArtifactName: 'config.yaml',
          binary: binary,
        );

  @override
  String readConfigArtifact(BuiltInProxyNodePlan plan) {
    final configYaml =
        plan.files['built-in-proxies/olcrtc/${plan.nodeId}/config.yaml'];
    if (configYaml == null || configYaml.isEmpty) {
      throw StateError(
        'olcrtc node `${plan.name}` is missing config.yaml artifact.',
      );
    }
    return configYaml;
  }

  @override
  OlcRtcNodeLayout resolveNodeLayout(
    OlcRtcSharedInstallLayout sharedLayout,
    String nodeId,
  ) {
    final workingDirectoryPath =
        path.join(sharedLayout.nodesDirectoryPath, nodeId);
    return OlcRtcNodeLayout(
      nodeId: nodeId,
      workingDirectoryPath: workingDirectoryPath,
      configPath: path.join(workingDirectoryPath, olcRtcConfigFileName),
    );
  }

  List<String> _buildArguments(OlcRtcNodeLayout layout) => [layout.configPath];

  @override
  Future<bool> startPlan(
    OlcRtcSharedInstallLayout sharedLayout,
    BuiltInProxyNodePlan plan,
    OlcRtcNodeLayout layout,
  ) =>
      runtime.startNode(
        nodeId: plan.nodeId,
        executablePath: sharedLayout.executablePath,
        workingDirectory: layout.workingDirectoryPath,
        arguments: _buildArguments(layout),
      );

  @override
  Future<LocalNodeColdStartExtras> buildColdStartExtras(
    BuiltInProxyNodePlan plan,
    OlcRtcSharedInstallLayout sharedLayout,
    OlcRtcNodeLayout layout,
  ) async =>
      LocalNodeColdStartExtras(
        extraFields: {
          'arguments': _buildArguments(layout),
        },
      );

  @override
  Future<String> rollbackStageFailure({
    required List<LocalNodeMutation<OlcRtcNodeLayout>> mutations,
    required String failureMessage,
  }) =>
      rollbackStageFailureWithRestart(
        mutations: mutations,
        failureMessage: failureMessage,
      );

  @override
  Future<void> handleStartNodesException({
    required Object error,
    required StackTrace stackTrace,
    required List<BuiltInProxyNodePlan> startedNodes,
  }) =>
      rethrowStartNodesExceptionWithCleanup(
        error: error,
        stackTrace: stackTrace,
        startedNodes: startedNodes,
      );
}
