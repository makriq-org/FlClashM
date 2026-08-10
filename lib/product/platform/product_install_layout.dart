import 'package:path/path.dart' as path;

/// Names consumed by both artifact assembly and the runtime supervisor.
///
/// Platform-specific packaging may choose the root, but never the structure
/// below it: `<root>/runtimes/<target>/<architecture>/<artifact>`.
class ProductInstallLayout {
  const ProductInstallLayout._();

  static const desktopApplicationId = 'app.flclashm.client';
  static const desktopHelperName = '$desktopApplicationId.helper';
  static const runtimeDirectoryName = 'runtimes';

  static const linuxTarget = 'linux';
  static const windowsTarget = 'windows';
  static const macosTarget = 'macos';
  static const x64Architecture = 'x86_64';
  static const arm64Architecture = 'arm64';

  /// Runtime coordinates for which the release pipeline produces a complete
  /// inventory. Linux and Windows arm64 are intentionally not advertised.
  static const supportedDesktopRuntimeCoordinates = <String, List<String>>{
    linuxTarget: [x64Architecture],
    windowsTarget: [x64Architecture],
    macosTarget: [x64Architecture, arm64Architecture],
  };

  static const mihomoArtifact = 'mihomo';
  static const helperArtifact = desktopHelperName;
  static const naiveproxyArtifact = 'naiveproxy';
  static const olcrtcArtifact = 'olcrtc';
  static const byedpiArtifact = 'byedpi';
  static const stormdnsArtifact = 'stormdns';

  static const artifacts = <String>[
    mihomoArtifact,
    helperArtifact,
    naiveproxyArtifact,
    olcrtcArtifact,
    byedpiArtifact,
    stormdnsArtifact,
  ];

  static String runtimeRoot({
    required String installRoot,
    required String target,
    required String architecture,
  }) => path.join(installRoot, runtimeDirectoryName, target, architecture);

  static String artifactPath({
    required String installRoot,
    required String target,
    required String architecture,
    required String artifact,
  }) {
    if (!artifacts.contains(artifact)) {
      throw ArgumentError.value(
        artifact,
        'artifact',
        'Unknown runtime artifact',
      );
    }
    return path.join(
      runtimeRoot(
        installRoot: installRoot,
        target: target,
        architecture: architecture,
      ),
      artifactFileName(target: target, artifact: artifact),
    );
  }

  static bool supportsDesktopRuntime({
    required String target,
    required String architecture,
  }) =>
      supportedDesktopRuntimeCoordinates[target]?.contains(architecture) ??
      false;

  static String artifactFileName({
    required String target,
    required String artifact,
  }) {
    if (!artifacts.contains(artifact)) {
      throw ArgumentError.value(
        artifact,
        'artifact',
        'Unknown runtime artifact',
      );
    }
    return target == windowsTarget ? '$artifact.exe' : artifact;
  }
}
