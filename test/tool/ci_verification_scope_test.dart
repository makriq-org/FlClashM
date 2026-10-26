import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  final workflow = loadYaml(
    File('.github/workflows/android-base-verification.yaml').readAsStringSync(),
  ) as YamlMap;
  final steps = workflow['jobs']['detect-changes']['steps'] as YamlList;
  final script =
      steps.firstWhere((step) => step['id'] == 'changes')['run'] as String;

  Future<void> expectScope(
    List<String> files,
    List<bool> expected, {
    String event = 'pull_request',
    String base = 'base',
    bool baseAvailable = true,
    bool e2eOnly = false,
    bool arm64Only = false,
  }) async {
    final directory = Directory.systemTemp.createTempSync('ci-scope-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final output = File('${directory.path}/output');
    final result = await Process.run(
      'bash',
      [
        '--noprofile',
        '--norc',
        '-e',
        '-o',
        'pipefail',
        '-c',
        // Supply changed paths without depending on the local Git history.
        '''git() {
  if [ "\$1" = cat-file ]; then
    [ "\$BASE_AVAILABLE" = true ]
  else
    printf '%s\\n' "\$CHANGED_FILES"
  fi
}
$script''',
      ],
      environment: {
        'CHANGED_FILES': files.join('\n'),
        'EVENT_NAME': event,
        'E2E_ONLY': '$e2eOnly',
        'ARM64_ONLY': '$arm64Only',
        'BASE_SHA': base,
        'BASE_AVAILABLE': '$baseAvailable',
        'HEAD_SHA': 'head',
        'GITHUB_OUTPUT': output.path,
      },
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final values = output.readAsLinesSync().map((line) => line.split('=').last);
    expect(values, expected.map((value) => '$value'));
  }

  // Order: base guards, Android unit tests/arm64 APK, extra ABI, emulator E2E.
  for (final path in [
    'test/product/backend_client_test.dart',
    'test/tool/release_contract_test.dart',
    'tool/check_release_continuity.dart',
    'analysis_options.yaml',
    'CHANGELOG.md',
  ]) {
    test('$path runs guards without Android builds', () async {
      await expectScope([path], [true, false, false, false]);
    });
  }

  for (final path in [
    'android/app/build.gradle.kts',
    'core/backend/coordinator.go',
    'assets/runtimes/byedpi/android/release.txt',
    'plugins/proxy/android/build.gradle',
    'pubspec.yaml',
    'pubspec.lock',
    'setup.dart',
    'tool/prepare_core.sh',
    'tool/patches/mihomo-android-system-dns-lock.patch',
    'tool/runtime_go_modules/olcrtc.mod',
    'lib/product/runtime/olcrtc_release.dart',
    '.github/workflows/android-base-verification.yaml',
    '.github/actions/build-arm64-smoke/action.yaml',
    '.github/actions/setup-editor-rust/action.yaml',
    '.github/scripts/arm64_runner_fallback.py',
  ]) {
    test('$path keeps full Android coverage', () async {
      await expectScope([path], [true, true, true, true]);
    });
  }

  test('UI and ordinary assets keep arm64 compilation', () async {
    for (final path in ['lib/views/proxies.dart', 'assets/images/logo.png']) {
      await expectScope([path], [true, true, false, false]);
    }
  });

  for (final path in [
    'lib/product/android/android_shell_bridge.dart',
    'lib/product/backend/backend_client.dart',
    'lib/product/bootstrap/app_bootstrap.dart',
    'lib/clash/lib.dart',
    'lib/state.dart',
    'lib/controller.dart',
  ]) {
    test('$path keeps E2E coverage for the UI backend bridge', () async {
      await expectScope([path], [true, true, false, true]);
    });
  }

  test('E2E script changes run the emulator', () async {
    await expectScope(
      ['.github/scripts/run-android-emulator-e2e.sh'],
      [false, false, false, true],
    );
  });

  test('documentation skips build and test jobs', () async {
    await expectScope(
      ['i18n/ru/docs/profiles.md'],
      [false, false, false, false],
    );
  });

  test('mixed changes preserve the widest required scope', () async {
    await expectScope(
      ['test/tool/release_contract_test.dart', 'core/backend/coordinator.go'],
      [true, true, true, true],
    );
  });

  test('manual runs and unknown bases run every check', () async {
    await expectScope([], [true, true, true, true], event: 'workflow_dispatch');
    await expectScope([], [true, true, true, true], base: '');
    await expectScope([], [
      true,
      true,
      true,
      true,
    ], base: '0000000000000000000000000000000000000000');
  });

  test('manual benchmarks run only E2E', () async {
    await expectScope(
      [],
      [false, false, false, true],
      event: 'workflow_dispatch',
      e2eOnly: true,
    );
  });

  test('manual ARM64 verification excludes emulator and extra ABI', () async {
    await expectScope(
      [],
      [false, true, false, false],
      event: 'workflow_dispatch',
      arm64Only: true,
    );
  });

  test('ARM64-only input cannot reduce automatic verification', () async {
    await expectScope(
      ['core/backend/coordinator.go'],
      [true, true, true, true],
      arm64Only: true,
    );
  });

  test('push with an unavailable previous commit runs every check', () async {
    await expectScope(
      ['i18n/ru/docs/profiles.md'],
      [true, true, true, true],
      event: 'push',
      baseAvailable: false,
    );
  });

  test('E2E-only input cannot reduce automatic verification', () async {
    await expectScope(
      ['core/backend/coordinator.go'],
      [true, true, true, true],
      e2eOnly: true,
    );
  });
}
