import 'dart:io';

import 'package:flclashx/product/services/desktop_app_update_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late File receiptFile;
  String? marker;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('flclashm-install-result-');
    receiptFile = File('${directory.path}/user/updates/seen.result');
    marker = null;
  });

  tearDown(() => directory.delete(recursive: true));

  test('reports a completed install only once for each user', () async {
    marker = '0.11.0-pre1:success:20260925093000';
    final store = WindowsInstallResultStore(
      readResult: () => marker,
      receiptFile: receiptFile,
    );

    final first = await store.consume();
    expect(first?.version, '0.11.0-pre1');
    expect(first?.outcome, WindowsInstallOutcome.success);
    expect(await store.consume(), isNull);

    marker = '0.11.0-pre1:failed:20260925110000';
    expect((await store.consume())?.outcome, WindowsInstallOutcome.failed);
  });

  test('reports failed restoration without trusting malformed markers', () async {
    final store = WindowsInstallResultStore(
      readResult: () => marker,
      receiptFile: receiptFile,
    );
    marker = '0.11.0:rollback-failed:20260925110000';
    expect(
      (await store.consume())?.outcome,
      WindowsInstallOutcome.rollbackFailed,
    );

    marker = '0.11.0:success:invalid';
    expect(await store.consume(), isNull);
    marker = 'A' * 257;
    expect(await store.consume(), isNull);
  });
}
