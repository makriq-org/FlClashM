import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Flutter assets contain only runtime data required at runtime', () {
    final pubspec = File('pubspec.yaml').readAsLinesSync();
    final runtimeAssets = pubspec
        .map((line) => line.trim())
        .where((line) => line.startsWith('- assets/runtimes/'))
        .toList();

    expect(runtimeAssets, const [
      '- assets/runtimes/byedpi/android/byebyeedpi-strategies.list',
    ]);
  });
}
