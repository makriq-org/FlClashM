import 'package:device_info_plus/device_info_plus.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flutter/foundation.dart';
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
    );
  }
}

class OlcRtcNodeController
    extends LocalNodeController<OlcRtcSharedInstallLayout, OlcRtcNodeLayout> {
  OlcRtcNodeController({
    OlcRtcBinaryBridge binary = const DefaultOlcRtcBinaryBridge(),
    super.runtime = const AndroidRuntimeNodeBridge(),
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
  Map<String, String> readAdditionalArtifacts(BuiltInProxyNodePlan plan) {
    if (plan.metadata['depends-on-system-dns'] != 'true') return const {};
    return {olcRtcConfigTemplateFileName: readConfigArtifact(plan)};
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
  Future<LocalNodeLaunchExtras> buildLaunchExtras(
    BuiltInProxyNodePlan plan,
    OlcRtcSharedInstallLayout sharedLayout,
    OlcRtcNodeLayout layout,
  ) async =>
      LocalNodeLaunchExtras(
        fields: {
          'arguments': _buildArguments(layout),
          if (plan.metadata['depends-on-system-dns'] == 'true')
            'resolverFile': <String, dynamic>{
              'template': olcRtcConfigTemplateFileName,
              'path': olcRtcConfigFileName,
              'dependsOnSystemDns': true,
              'systemDnsMode': 'single-host-port',
            },
        },
      );
}
