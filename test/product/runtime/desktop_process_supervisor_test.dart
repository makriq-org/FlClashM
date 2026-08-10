import 'dart:io';

import 'package:flclashx/product/runtime/desktop_process_supervisor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bounds and redacts child output before retaining it', () {
    final output = DesktopBoundedOutput(limit: 40)
      ..add('password=hello https://a:b@example.com ${'x' * 80}'.codeUnits);

    expect(output.value.length, lessThanOrEqualTo(40));
    expect(output.value, isNot(contains('hello')));
    expect(output.value, isNot(contains('a:b')));
  });

  test('redacts credentials split across output chunks', () {
    final output = DesktopBoundedOutput()..add('password=split'.codeUnits);
    expect(output.value, isNot(contains('split')));
    output
      ..add('Secret https://user:split'.codeUnits)
      ..add('Password@example.com'.codeUnits);

    expect(output.value, isNot(contains('splitSecret')));
    expect(output.value, isNot(contains('user:splitPassword')));
  });

  test('owns and stops a real Linux child process', () async {
    if (!Platform.isLinux) return;
    final supervisor = DesktopProcessSupervisor();
    final shell =
        Platform.environment['SHELL'] ?? '/run/current-system/sw/bin/bash';

    final handle = await supervisor.spawn(
      identity: 'smoke',
      executable: shell,
      arguments: const ['-c', 'while true; do sleep 1; done'],
    );
    expect(supervisor.childIdentities, contains('smoke'));
    await supervisor.stop('smoke');

    expect(await handle.process.exitCode, isNot(0));
    expect(supervisor.childIdentities, isNot(contains('smoke')));
  });

  test('serializes competing start and stop operations', () async {
    if (!Platform.isLinux) return;
    final supervisor = DesktopProcessSupervisor();
    final shell =
        Platform.environment['SHELL'] ?? '/run/current-system/sw/bin/bash';
    final first = supervisor.spawn(
      identity: 'race',
      executable: shell,
      arguments: const ['-c', 'sleep 30'],
    );
    final second = supervisor.spawn(
      identity: 'race',
      executable: shell,
      arguments: const ['-c', 'sleep 30'],
    );
    final stopping = supervisor.stop('race');

    await Future.wait([first, second, stopping]);
    expect(supervisor.childIdentities, isEmpty);
  });
}
