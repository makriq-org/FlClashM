import 'dart:convert';
import 'dart:io';

import 'package:flclashx/product/platform/product_install_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop release matrix exposes only supported runtime coordinates', () {
    expect(ProductInstallLayout.supportedDesktopRuntimeCoordinates, {
      'linux': ['x86_64'],
      'windows': ['x86_64'],
      'macos': ['x86_64', 'arm64'],
    });
    expect(
      ProductInstallLayout.supportsDesktopRuntime(
        target: 'linux',
        architecture: 'arm64',
      ),
      isFalse,
    );
    expect(
      ProductInstallLayout.supportsDesktopRuntime(
        target: 'windows',
        architecture: 'arm64',
      ),
      isFalse,
    );
  });

  test('production manifest matches the product install matrix', () {
    final manifest =
        jsonDecode(File('tool/runtime_compat/manifest.json').readAsStringSync())
            as Map<String, dynamic>;
    final targets = (manifest['targets'] as Map<String, dynamic>).values
        .cast<Map<String, dynamic>>()
        .map((entry) => '${entry['os']}:${entry['architecture']}')
        .toSet();
    final contract = ProductInstallLayout
        .supportedDesktopRuntimeCoordinates
        .entries
        .expand(
          (entry) =>
              entry.value.map((architecture) => '${entry.key}:$architecture'),
        )
        .toSet();
    expect(targets, contract);
  });

  test('artifact paths preserve platform executable naming', () {
    expect(
      ProductInstallLayout.artifactPath(
        installRoot: '/opt/flclashm',
        target: 'linux',
        architecture: 'x86_64',
        artifact: ProductInstallLayout.stormdnsArtifact,
      ),
      '/opt/flclashm/runtimes/linux/x86_64/stormdns',
    );
    expect(
      ProductInstallLayout.artifactPath(
        installRoot: r'C:\Program Files\FlClashM',
        target: 'windows',
        architecture: 'x86_64',
        artifact: ProductInstallLayout.naiveproxyArtifact,
      ),
      endsWith(r'runtimes/windows/x86_64/naiveproxy.exe'),
    );
  });
}
