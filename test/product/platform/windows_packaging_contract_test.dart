import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Windows package installs the named-pipe service and preserves data',
    () {
      final cmake = File('windows/CMakeLists.txt').readAsStringSync();
      final installer = File(
        'windows/packaging/exe/inno_setup.iss',
      ).readAsStringSync();
      final helper = File(
        'services/helper/src/service/windows.rs',
      ).readAsStringSync();

      expect(cmake, contains('FLCLASHM_WINDOWS_HELPER'));
      expect(cmake, isNot(contains('libclash/windows')));
      expect(
        installer,
        contains("HelperServiceName = 'app.flclashm.client.helper'"),
      );
      expect(installer, contains('StopAndRemoveHelperService'));
      expect(installer, contains('InstallAndStartHelperService'));
      expect(installer, contains('Удалить пользовательские данные программы?'));
      expect(helper, contains(r'\\.\pipe\app.flclashm.client.helper.v1'));
      expect(helper, contains('D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)'));
      expect(helper, isNot(contains('warp::')));
      expect(helper, isNot(contains('127.0.0.1')));
      expect(helper, isNot(contains('allowed_core.sha256')));
      expect(helper, isNot(contains('Command::new')));
    },
  );

  test('Windows CI exercises installer, service lifecycle and IPC', () {
    final workflow = File(
      '.github/workflows/windows-desktop-e2e.yml',
    ).readAsStringSync();
    expect(workflow, contains('Build bundle and Inno installer'));
    expect(workflow, contains('NamedPipeClientStream'));
    expect(workflow, contains('sc.exe query $service'));
    expect(workflow, contains('sc.exe delete $service'));
  });
}
