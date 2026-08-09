import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    globalState.config = const Config(
      themeProps: defaultThemeProps,
      patchClashConfig: ClashConfig(mixedPort: 7890),
    );
    globalState.appState = AppState(
      version: 1,
      viewSize: Size.zero,
      requests: FixedList(maxLength),
      logs: FixedList(maxLength),
      traffics: FixedList(30),
      totalTraffic: Traffic(),
    );
  });

  test('FlClashHttpOverrides never uses a local proxy listener', () {
    globalState.appState = globalState.appState.copyWith(runTime: 1);

    expect(
      FlClashHttpOverrides.handleFindProxy(Uri.parse('http://127.0.0.1:9090')),
      'DIRECT',
    );
    expect(
      FlClashHttpOverrides.handleFindProxy(Uri.parse('http://localhost:9090')),
      'DIRECT',
    );
    expect(
      FlClashHttpOverrides.handleFindProxy(Uri.parse('http://[::1]:9090')),
      'DIRECT',
    );
    expect(
      FlClashHttpOverrides.handleFindProxy(Uri.parse('https://example.com')),
      'DIRECT',
    );
  });

  test('FlClashHttpOverrides keeps direct traffic when runtime is inactive',
      () {
    expect(
      FlClashHttpOverrides.handleFindProxy(Uri.parse('https://example.com')),
      'DIRECT',
    );
  });

}
