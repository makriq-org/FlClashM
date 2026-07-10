import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'built_in_proxy_types.dart';
import 'local_node_controller.dart';
import 'naiveproxy_release.dart';

typedef WaitForRuntimeNodeListenerCallback = Future<void> Function(
  String host,
  int port,
);

@immutable
class NaiveProxySharedInstallLayout extends LocalNodeSharedInstallLayout {
  const NaiveProxySharedInstallLayout({
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
  String get bundledReleaseTag => naiveProxyPinnedReleaseTag;

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
      pendingPath: path.join(
        runtimeRootPath,
        '$naiveProxyExecutableFileName.pending',
      ),
      rollbackPath: path.join(
        runtimeRootPath,
        '$naiveProxyExecutableFileName.rollback',
      ),
      versionPath: path.join(
        runtimeRootPath,
        naiveProxyBundledVersionFileName,
      ),
      pendingVersionPath: path.join(
        runtimeRootPath,
        naiveProxyPendingVersionFileName,
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

class NaiveProxyNodeController extends LocalNodeController<
    NaiveProxySharedInstallLayout, NaiveProxyNodeLayout> {
  NaiveProxyNodeController({
    NaiveProxyBinaryBridge binary = const DefaultNaiveProxyBinaryBridge(),
    super.runtime = const AndroidRuntimeNodeBridge(),
    super.waitForListener = _waitForRuntimeNodeListener,
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

  @override
  Future<bool> startPlan(
    NaiveProxySharedInstallLayout sharedLayout,
    BuiltInProxyNodePlan plan,
    NaiveProxyNodeLayout layout,
  ) =>
      runtime.startNode(
        nodeId: plan.nodeId,
        executablePath: sharedLayout.executablePath,
        workingDirectory: layout.workingDirectoryPath,
      );

  @override
  Future<String> rollbackStageFailure({
    required List<LocalNodeMutation<NaiveProxyNodeLayout>> mutations,
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

  static Future<void> _waitForRuntimeNodeListener(
    String host,
    int port,
  ) async {
    final uri = Uri(
      scheme: 'socks5',
      host: host,
      port: port,
    );
    for (var attempt = 0; attempt < 50; attempt++) {
      try {
        final socket = await Socket.connect(
          uri.host,
          uri.port,
          timeout: const Duration(milliseconds: 200),
        );
        await socket.close();
        return;
      } catch (_) {
        if (attempt == 49) {
          throw StateError(
            'Timed out waiting for local runtime node listener on '
            '${uri.host}:${uri.port}.',
          );
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }
}
