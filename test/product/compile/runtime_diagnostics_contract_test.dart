import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('profile diagnostics notify only while in-app logs are enabled', () {
    final stateSource = File('lib/state.dart').readAsStringSync();
    final loopStart = stateSource
        .indexOf('for (final diagnostic in runtimePlan.diagnostics)');
    expect(loopStart, greaterThan(0));
    final loop = stateSource.substring(loopStart, loopStart + 240);
    expect(loop, contains('commonPrint.log(diagnostic);'));
    expect(loop, contains('if (config.appSetting.openLogs)'));
    expect(
      loop.indexOf('showNotifier(diagnostic);'),
      greaterThan(loop.indexOf('if (config.appSetting.openLogs)')),
    );
  });
}
