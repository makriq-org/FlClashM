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

  test('system aliases select fixed artwork without duplicating it', () {
    Map<String, String> aliases(String qualifier) => {
      for (final item in XmlDocument.parse(
        File('android/app/src/main/res/values$qualifier/brand_aliases.xml')
            .readAsStringSync(),
      ).findAllElements('item'))
        item.getAttribute('name')!: item.innerText,
    };
    final day = aliases('');
    final night = aliases('-night');
    expect(day['ic_launcher_foreground'], '@drawable/brand_light');
    expect(night['ic_launcher_foreground'], '@drawable/brand_dark');
    expect(day['ic_launcher'], '@mipmap/launcher_light');
    expect(night['ic_launcher'], '@mipmap/launcher_dark');
    for (final palette in ['light', 'dark', 'black']) {
      final icon = XmlDocument.parse(
        File('android/app/src/main/res/mipmap-anydpi-v26/launcher_$palette.xml')
            .readAsStringSync(),
      );
      final bird = palette == 'light' ? 'light' : 'dark';
      expect(
        icon
            .findAllElements('foreground')
            .single
            .findElements('inset')
            .single
            .getAttribute('android:drawable'),
        '@drawable/brand_$bird',
      );
      expect(
        icon
            .findAllElements('background')
            .single
            .getAttribute('android:drawable'),
        '@color/brand_${palette}_background',
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
