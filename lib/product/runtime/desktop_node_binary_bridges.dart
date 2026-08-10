import 'package:flclashx/common/common.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../platform/product_install_layout.dart';
import 'byedpi_node_controller.dart';
import 'byedpi_release.dart';
import 'desktop_runtime_layout.dart';
import 'naiveproxy_node_controller.dart';
import 'olcrtc_node_controller.dart';
import 'stormdns_node_controller.dart';

Future<DesktopRuntimeLayout> _layout() async =>
    DesktopRuntimeLayout.current(dataRoot: await appPath.homeDirPath);

class DesktopNaiveProxyBinaryBridge implements NaiveProxyBinaryBridge {
  const DesktopNaiveProxyBinaryBridge();

  @override
  Future<NaiveProxySharedInstallLayout> resolveSharedInstallLayout() async {
    final layout = await _layout();
    return NaiveProxySharedInstallLayout(
      abi: layout.architecture,
      runtimeRootPath: path.join(layout.dataRoot, 'desktop-runtime'),
      nodesDirectoryPath: layout.nodesRoot,
      executablePath: await layout.requireArtifact(
        ProductInstallLayout.naiveproxyArtifact,
      ),
    );
  }
}

class DesktopOlcRtcBinaryBridge implements OlcRtcBinaryBridge {
  const DesktopOlcRtcBinaryBridge();

  @override
  Future<OlcRtcSharedInstallLayout> resolveSharedInstallLayout() async {
    final layout = await _layout();
    return OlcRtcSharedInstallLayout(
      abi: layout.architecture,
      runtimeRootPath: path.join(layout.dataRoot, 'desktop-runtime'),
      nodesDirectoryPath: layout.nodesRoot,
      executablePath: await layout.requireArtifact(
        ProductInstallLayout.olcrtcArtifact,
      ),
    );
  }
}

class DesktopStormDnsBinaryBridge implements StormDnsBinaryBridge {
  const DesktopStormDnsBinaryBridge();

  @override
  Future<StormDnsSharedInstallLayout> resolveSharedInstallLayout() async {
    final layout = await _layout();
    return StormDnsSharedInstallLayout(
      abi: layout.architecture,
      runtimeRootPath: path.join(layout.dataRoot, 'desktop-runtime'),
      nodesDirectoryPath: layout.nodesRoot,
      executablePath: await layout.requireArtifact(
        ProductInstallLayout.stormdnsArtifact,
      ),
    );
  }
}

class DesktopByedpiBinaryBridge implements ByedpiBinaryBridge {
  const DesktopByedpiBinaryBridge();

  @override
  String get bundledReleaseTag => byedpiPinnedReleaseTag;

  @override
  Future<String> loadBundledStrategyList(String assetPath) =>
      rootBundle.loadString(assetPath);

  @override
  Future<ByedpiSharedInstallLayout> resolveSharedInstallLayout() async {
    final layout = await _layout();
    return ByedpiSharedInstallLayout(
      abi: layout.architecture,
      runtimeRootPath: path.join(layout.dataRoot, 'desktop-runtime'),
      nodesDirectoryPath: layout.nodesRoot,
      executablePath: await layout.requireArtifact(
        ProductInstallLayout.byedpiArtifact,
      ),
    );
  }
}
