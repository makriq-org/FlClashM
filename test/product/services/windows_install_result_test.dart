import 'dart:io';

import 'package:flclashx/product/services/desktop_app_update_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late File resultFile;
  late File receiptFile;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('flclashm-install-result-');
    resultFile = File('${directory.path}/machine/windows-install.result');
    receiptFile = File('${directory.path}/user/updates/seen.result');
    await resultFile.parent.create(recursive: true);
  });

  tearDown(() => directory.delete(recursive: true));

  test('reports a completed install only once for each user', () async {
    await resultFile.writeAsString('0.11.0-pre1:success:20260925093000');
    final store = WindowsInstallResultStore(
      resultFile: resultFile,
      receiptFile: receiptFile,
    );

    final first = await store.consume();
    expect(first?.version, '0.11.0-pre1');
    expect(first?.outcome, WindowsInstallOutcome.success);
    expect(await store.consume(), isNull);

    await resultFile.writeAsString('0.11.0-pre1:failed:20260925110000');
    expect((await store.consume())?.outcome, WindowsInstallOutcome.failed);
  });

  test('reports failed restoration without trusting malformed markers', () async {
    final store = WindowsInstallResultStore(
      resultFile: resultFile,
      receiptFile: receiptFile,
    );
    await resultFile.writeAsString('0.11.0:rollback-failed:20260925110000');
    expect(
      (await store.consume())?.outcome,
      WindowsInstallOutcome.rollbackFailed,
    );

    await resultFile.writeAsString('0.11.0:success:invalid');
    expect(await store.consume(), isNull);
    await resultFile.writeAsBytes(List<int>.filled(257, 65));
    expect(await store.consume(), isNull);
  });
}
