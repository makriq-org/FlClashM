import 'package:flutter/services.dart';

import 'package:material_ui/material_ui.dart';

import '../../common/constant.dart';
import '../../ui/color.dart';
import '../../ui/shape.dart';
import '../../ui/surface.dart';
import '../../ui/typography.dart';

/// A disposable first-frame projection, never an authority for settings.
/// Android needs it before Go and the provider container are available.
class StartupAppearance {
  const StartupAppearance({
    this.mode = ThemeMode.system,
    this.pureBlack = false,
  });

  final ThemeMode mode;
  final bool pureBlack;
  static const _channel = MethodChannel(
    'com.makriq.flclash/startup_appearance',
  );

  Color background(Brightness brightness) => brightness == Brightness.light
      ? const Color(0xffeeedef)
      : pureBlack
      ? const Color(0xff000000)
      : const Color(0xff121315);

  ThemeData theme(Brightness brightness) {
    final scheme = seededColorScheme(
      seedColor: const Color(defaultPrimaryColor),
      brightness: brightness,
    );
    return ThemeData(useMaterial3: true, colorScheme: scheme)
        .withAppShapes
        .withAppSurfaces
        .withAppTypography
        .copyWith(scaffoldBackgroundColor: background(brightness));
  }

  static Future<StartupAppearance> read() async {
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>('read');
      return StartupAppearance(
        mode: ThemeMode.values.firstWhere(
          (mode) => mode.name == data?['themeMode'],
          orElse: () => ThemeMode.system,
        ),
        pureBlack: data?['pureBlack'] == true,
      );
    } on PlatformException {
      return const StartupAppearance();
    } on MissingPluginException {
      return const StartupAppearance();
    }
  }
}
