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

  static const mihomoArtifact = 'mihomo';
  static const helperArtifact = 'helper';
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
  }) =>
      path.join(installRoot, runtimeDirectoryName, target, architecture);

  static String artifactPath({
    required String installRoot,
    required String target,
    required String architecture,
    required String artifact,
  }) {
    if (!artifacts.contains(artifact)) {
      throw ArgumentError.value(
          artifact, 'artifact', 'Unknown runtime artifact');
    }
    return path.join(
      runtimeRoot(
        installRoot: installRoot,
        target: target,
        architecture: architecture,
      ),
      artifact,
    );
  }
}
