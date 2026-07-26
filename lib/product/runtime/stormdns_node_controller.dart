import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'built_in_proxy_types.dart';
import 'local_node_controller.dart';
import 'stormdns_release.dart';

@immutable
class StormDnsSharedInstallLayout extends LocalNodeSharedInstallLayout {
  const StormDnsSharedInstallLayout({
    required super.abi,
    required super.runtimeRootPath,
    required super.nodesDirectoryPath,
    required super.executablePath,
  });
}

@immutable
class StormDnsNodeLayout extends LocalNodeLayout {
  const StormDnsNodeLayout({
    required super.nodeId,
    required super.workingDirectoryPath,
    required super.configPath,
    required this.resolversPath,
    required this.resolversTemplatePath,
  });

  /// Generated file the process reads; owned by the platform.
  final String resolversPath;

  /// Staged template the platform renders from; owned by the profile.
  final String resolversTemplatePath;
}

abstract interface class StormDnsBinaryBridge
    extends LocalNodeBinaryBridge<StormDnsSharedInstallLayout> {}

class DefaultStormDnsBinaryBridge implements StormDnsBinaryBridge {
  const DefaultStormDnsBinaryBridge({
    this.nativeLibrary = const AndroidRuntimeNodeNativeLibraryBridge(),
  });

  final AndroidRuntimeNodeNativeLibraryBridge nativeLibrary;

  @override
  Future<StormDnsSharedInstallLayout> resolveSharedInstallLayout() async {
    final deviceInfo = await DeviceInfoPlugin().androidInfo;
    StormDnsReleaseAsset? asset;
    for (final abi in deviceInfo.supportedAbis) {
      final candidate = stormDnsReleaseAssets[abi];
      if (candidate != null) {
        asset = candidate;
        break;
      }
    }
    if (asset == null) {
      throw UnsupportedError(
        'stormdns is not packaged for Android ABIs: '
        '${deviceInfo.supportedAbis.join(', ')}',
      );
    }

    final homeDir = await appPath.homeDirPath;
    final runtimeRootPath = path.join(
      homeDir,
      'runtimes',
      stormDnsRuntimeDirectoryName,
      asset.abi,
    );
    final executablePath = await nativeLibrary.resolvePath(
      stormDnsAndroidNativeLibraryFileName,
    );
    if (executablePath == null) {
      throw StateError(
        'Bundled native stormdns library '
        '$stormDnsAndroidNativeLibraryFileName is missing. Run '
        '`dart setup.dart android --out runtime-assets` before building.',
      );
    }

    return StormDnsSharedInstallLayout(
      abi: asset.abi,
      runtimeRootPath: runtimeRootPath,
      nodesDirectoryPath: path.join(runtimeRootPath, 'nodes'),
      executablePath: executablePath,
    );
  }
}

class StormDnsNodeController extends LocalNodeController<
    StormDnsSharedInstallLayout, StormDnsNodeLayout> {
  StormDnsNodeController({
    StormDnsBinaryBridge binary = const DefaultStormDnsBinaryBridge(),
    super.runtime = const AndroidRuntimeNodeBridge(),
  }) : super(
          typeLabel: 'stormdns',
          configArtifactName: stormDnsConfigFileName,
          binary: binary,
        );

  @override
  String readConfigArtifact(BuiltInProxyNodePlan plan) {
    final config = plan.files[
        'built-in-proxies/stormdns/${plan.nodeId}/$stormDnsConfigFileName'];
    if (config == null || config.isEmpty) {
      throw StateError(
        'stormdns node `${plan.name}` is missing its '
        '$stormDnsConfigFileName artifact.',
      );
    }
    return config;
  }

  @override
  Map<String, String> readAdditionalArtifacts(BuiltInProxyNodePlan plan) {
    final resolvers = plan.files['built-in-proxies/stormdns/${plan.nodeId}/'
        '$stormDnsResolversTemplateFileName'];
    if (resolvers == null || resolvers.isEmpty) {
      throw StateError(
        'stormdns node `${plan.name}` is missing its '
        '$stormDnsResolversTemplateFileName artifact.',
      );
    }
    return {stormDnsResolversTemplateFileName: resolvers};
  }

  @override
  StormDnsNodeLayout resolveNodeLayout(
    StormDnsSharedInstallLayout sharedLayout,
    String nodeId,
  ) {
    final workingDirectoryPath =
        path.join(sharedLayout.nodesDirectoryPath, nodeId);
    return StormDnsNodeLayout(
      nodeId: nodeId,
      workingDirectoryPath: workingDirectoryPath,
      configPath: path.join(workingDirectoryPath, stormDnsConfigFileName),
      resolversPath: path.join(workingDirectoryPath, stormDnsResolversFileName),
      resolversTemplatePath:
          path.join(workingDirectoryPath, stormDnsResolversTemplateFileName),
    );
  }

  @override
  Future<LocalNodeLaunchExtras> buildLaunchExtras(
    BuiltInProxyNodePlan plan,
    StormDnsSharedInstallLayout sharedLayout,
    StormDnsNodeLayout layout,
  ) async {
    final cacheDirectory = plan.metadata['cache-directory'];
    return LocalNodeLaunchExtras(
      fields: {
        'arguments': <String>[
          '-config',
          layout.configPath,
          '-resolvers',
          layout.resolversPath,
        ],
        // StormDNS blocks on stdin ("Press Enter to exit...") when startup
        // fails, which would keep a dead process alive forever on Android.
        'closeStdin': true,
        'resolverFile': <String, dynamic>{
          'template': stormDnsResolversTemplateFileName,
          'path': stormDnsResolversFileName,
          'dependsOnSystemDns':
              plan.metadata['depends-on-system-dns'] == 'true',
          if (cacheDirectory != null) 'resetPaths': <String>[cacheDirectory],
        },
      },
    );
  }

  /// Drops working caches built for a superseded resolver/domain fingerprint.
  ///
  /// Runs only after the plan commits, so a rollback still finds the cache the
  /// previous plan was using.
  @override
  Future<void> commitNode(
    BuiltInProxyNodePlan plan,
    StormDnsSharedInstallLayout sharedLayout,
    StormDnsNodeLayout layout,
  ) async {
    final fingerprint = plan.metadata['cache-fingerprint'];
    if (fingerprint == null || fingerprint.isEmpty) return;
    final cacheRoot = Directory(
      path.join(layout.workingDirectoryPath, stormDnsCacheDirectoryName),
    );
    if (!cacheRoot.existsSync()) return;
    try {
      for (final entry in cacheRoot.listSync()) {
        if (entry is! Directory) continue;
        if (path.basename(entry.path) == fingerprint) continue;
        await entry.delete(recursive: true);
      }
    } catch (error) {
      commonPrint.log(
        'stormdns node `${plan.name}` kept a stale working cache: $error',
      );
    }
  }
}
