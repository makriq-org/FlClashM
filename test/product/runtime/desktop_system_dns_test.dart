import 'dart:io';

import 'package:flclashx/product/runtime/desktop_system_dns.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads resolver addresses on Linux', () async {
    final reader = DesktopSystemDns(
      target: 'linux',
      readFile: (_) async =>
          'nameserver 1.1.1.1\nnameserver 2001:4860:4860::8888',
    );

    expect(await reader.read(), ['1.1.1.1', '2001:4860:4860::8888']);
  });

  test('reads resolver addresses on macOS', () async {
    final reader = DesktopSystemDns(
      target: 'macos',
      runCommand: (_, __) async => ProcessResult(
        1,
        0,
        '  nameserver[0] : 1.1.1.1\n  nameserver[1] : 2606:4700:4700::1111',
        '',
      ),
    );

    expect(await reader.read(), ['1.1.1.1', '2606:4700:4700::1111']);
  });

  test('reads locale-independent Windows DNS while excluding the TUN adapter',
      () async {
    final reader = DesktopSystemDns(
      target: 'windows',
      runCommand: (executable, arguments) async {
        expect(executable, 'powershell.exe');
        expect(arguments.last, contains(r"$_.Name -ne 'FlClashM'"));
        return ProcessResult(
            1, 0, '["9.9.9.9","149.112.112.112","9.9.9.9"]', '');
      },
    );
    expect(await reader.read(), ['9.9.9.9', '149.112.112.112']);
  });
}
