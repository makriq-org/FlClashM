import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as path;

import '../platform/product_install_layout.dart';

class DesktopRuntimeLayout {
  const DesktopRuntimeLayout({
    required this.installRoot,
    required this.target,
    required this.architecture,
    required this.dataRoot,
  });

  factory DesktopRuntimeLayout.current({String? dataRoot}) =>
      DesktopRuntimeLayout(
        installRoot: Platform.isMacOS
            ? path.dirname(path.dirname(Platform.resolvedExecutable))
            : path.dirname(Platform.resolvedExecutable),
        target: Platform.operatingSystem,
        architecture: switch (Abi.current()) {
          Abi.linuxX64 || Abi.windowsX64 || Abi.macosX64 => 'x86_64',
          Abi.linuxArm64 || Abi.windowsArm64 || Abi.macosArm64 => 'arm64',
          _ => throw UnsupportedError(
              'FlClashM has no runtime layout for `${Abi.current()}`.',
            ),
        },
        dataRoot: dataRoot ?? '',
      );

  final String installRoot;
  final String target;
  final String architecture;
  final String dataRoot;

  String artifactPath(String artifact) => ProductInstallLayout.artifactPath(
        installRoot: installRoot,
        target: target,
        architecture: architecture,
        artifact: artifact,
      );

  String get nodesRoot => path.join(dataRoot, 'desktop-runtime', 'nodes');

  Future<String> requireArtifact(String artifact) async {
    final expected = path.normalize(path.absolute(artifactPath(artifact)));
    final runtimeRoot = path.normalize(
      path.absolute(
        ProductInstallLayout.runtimeRoot(
          installRoot: installRoot,
          target: target,
          architecture: architecture,
        ),
      ),
    );
    if (!path.isWithin(runtimeRoot, expected)) {
      throw StateError('Runtime artifact escaped the install layout.');
    }
    final file = File(expected);
    if (!file.existsSync()) {
      throw StateError('Bundled runtime artifact `$artifact` is missing.');
    }
    if (target != 'windows') {
      final stat = file.statSync();
      if (stat.mode & 0x49 == 0) {
        throw StateError(
          'Bundled runtime artifact `$artifact` is not executable.',
        );
      }
    }
    return expected;
  }
}
