import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS helper uses a narrow unsigned-compatible install boundary', () {
    final helper = File('macos/Helper/main.swift').readAsStringSync();
    final installer = File('macos/Helper/install-helper.sh').readAsStringSync();
    final bridge = File(
      'macos/Runner/ProductPlatformBridge.swift',
    ).readAsStringSync();

    expect(helper, contains(r'/var/run/\(identity).helper.sock'));
    expect(helper, contains('getpeereid'));
    expect(helper, contains('peerUID == consoleUID()'));
    expect(helper, contains('inet 198.18.0.1'));
    expect(helper, contains('requested == "FlClashM"'));
    expect(helper, contains('Executable paths and arguments are forbidden'));
    expect(helper, contains('Runtime processes must remain unprivileged'));
    expect(helper, isNot(contains('setuid')));
    expect(installer, contains('/Library/PrivilegedHelperTools/'));
    expect(installer, contains('/Library/LaunchDaemons/'));
    expect(installer, contains('launchctl bootstrap system'));
    expect(bridge, contains('with administrator privileges'));
    expect(bridge, isNot(contains('SMJobBless')));
  });

  test('macOS packaging keeps Gatekeeper policy explicit', () {
    final package = File('macos/packaging/package.sh').readAsStringSync();
    final documentation = File('macos/packaging/README.md').readAsStringSync();
    final updater = File('macos/Updater/main.swift').readAsStringSync();

    expect(package, contains('hdiutil create'));
    expect(package, contains(r'FlClashM-$target.zip'));
    expect(package, isNot(contains('codesign')));
    expect(package, isNot(contains('xattr')));
    expect(documentation, contains('Gatekeeper'));
    expect(documentation, contains('notarization'));
    expect(updater, contains('.FlClashM-previous-'));
    expect(updater, contains('moveItem(at: previous, to: current)'));
    expect(updater, contains('CFBundleIdentifier'));
  });
}
