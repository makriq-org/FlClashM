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

  test('system day/night resources retain black mode and icon contrast', () {
    String color(String directory, String file, String name) {
      final doc = XmlDocument.parse(
        File('android/app/src/main/res/$directory/$file.xml')
            .readAsStringSync(),
      );
      return doc
          .findAllElements('color')
          .singleWhere((e) => e.getAttribute('name') == name)
          .innerText;
    }

    int argb(String hex) => int.parse(hex.substring(1), radix: 16) | 0xff000000;
    for (final brightness in Brightness.values) {
      final directory = brightness == Brightness.light
          ? 'values'
          : 'values-night';
      expect(
        argb(color(directory, 'startup', 'startup_system_background')),
        const StartupAppearance(pureBlack: true)
            .theme(brightness)
            .scaffoldBackgroundColor
            .toARGB32(),
      );
      final icon = color(directory, 'colors', 'ic_launcher_background');
      expect(
        argb(icon),
        const StartupAppearance()
            .theme(brightness)
            .scaffoldBackgroundColor
            .toARGB32(),
      );
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
      expect(
        activities['com.follow.clashx.MainActivity']!.getAttribute(
          'android:launchMode',
        ),
        'singleTask',
      );
      for (final alias in aliases) {
        final target =
            activities[alias.getAttribute('android:targetActivity')]!;
        expect(target.getAttribute('android:noHistory'), 'true');
        expect(target.getAttribute('android:relinquishTaskIdentity'), 'true');
      }
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
