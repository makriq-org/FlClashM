import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:material_ui/material_ui.dart';

import '../../common/constant.dart';
import '../../providers/providers.dart';
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

  ThemeData theme(Brightness brightness) {
    final scheme = seededColorScheme(
      seedColor: const Color(defaultPrimaryColor),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
    ).withAppShapes.withAppSurfaces.withAppTypography.copyWith(
      scaffoldBackgroundColor: brightness == Brightness.light
          ? const Color(0xffeeedef)
          : pureBlack
          ? const Color(0xff000000)
          : const Color(0xff121315),
    );
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

  static void bind(ProviderContainer container) {
    Map<String, Object>? previous;
    var pending = Future<void>.value();
    void sync() {
      final data = <String, Object>{
        'themeMode': container.read(themeSettingProvider).themeMode.name,
        'pureBlack': container.read(themeSettingProvider).pureBlack,
      };
      if (previous != null &&
          data.entries.every((e) => previous![e.key] == e.value)) {
        return;
      }
      previous = data;
      // Serialize writes so a fast theme change cannot leave an older cache.
      pending = pending.then((_) async {
        try {
          await _channel.invokeMethod<void>('write', data);
        } on PlatformException {
          // Cosmetic cache: startup and settings must remain usable without it.
        } on MissingPluginException {
          // Desktop hosts do not implement the Android first-frame cache.
        }
      });
      unawaited(pending);
    }

    container.listen(themeSettingProvider, (_, _) => sync());
    sync();
  }
}
