import 'dart:io';

import 'package:flclashx/product/bootstrap/startup_appearance.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xml/xml.dart';

void main() {
  test('native and Flutter starting surfaces share the fixed palette', () {
    final resources = XmlDocument.parse(
      File('android/app/src/main/res/values/startup.xml').readAsStringSync(),
    );
    final colors = {
      for (final node in resources.findAllElements('color'))
        node.getAttribute('name'):
            int.parse(node.innerText.substring(1), radix: 16) | 0xff000000,
    };
    for (final black in [false, true]) {
      for (final brightness in Brightness.values) {
        final name = brightness == Brightness.light
            ? 'light'
            : black
            ? 'black'
            : 'dark';
        expect(
          StartupAppearance(pureBlack: black)
              .theme(brightness)
              .scaffoldBackgroundColor
              .toARGB32(),
          colors['brand_${name}_background'],
        );
      }
    }
  });

  test(
    'launcher variants have explicit native themes and one default entry',
    () {
      final manifest = XmlDocument.parse(
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
      );
      final aliases = manifest
          .findAllElements('activity-alias')
          .where((e) => e.getAttribute('android:name')!.startsWith('.Launcher'))
          .toList();
      expect(aliases.length, 5);
      expect(
        aliases
            .where((e) => e.getAttribute('android:enabled') == 'true')
            .single
            .getAttribute('android:name'),
        '.LauncherSystem',
      );
      final activities = {
        for (final node in manifest.findAllElements('activity'))
          node.getAttribute('android:name'): node,
      };
      for (final name in ['Light', 'Dark', 'Black', 'SystemBlack']) {
        final alias = aliases.singleWhere(
          (e) => e.getAttribute('android:name') == '.Launcher$name',
        );
        expect(
          activities[alias.getAttribute('android:targetActivity')]!
              .getAttribute('android:theme'),
          '@style/Startup$name',
        );
      }
    },
  );
}
