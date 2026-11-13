import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';
import '../../widgets/brand_mark.dart';
import 'startup_appearance.dart';

/// Stable root: the real application is mounted once, with no minimum delay.
class StartupHost extends StatelessWidget {
  const StartupHost({
    super.key,
    required this.content,
    this.appearance = const StartupAppearance(),
  });
  final ValueNotifier<Widget> content;
  final StartupAppearance appearance;

  @override
  Widget build(BuildContext context) {
    final brightness = switch (appearance.mode) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system => MediaQuery.platformBrightnessOf(context),
    };
    // HomePage can be empty until its first layout projects the view size.
    // Keep an opaque page surface behind both applications during hand-off.
    return ColoredBox(
      color: appearance.theme(brightness).scaffoldBackgroundColor,
      child: ValueListenableBuilder<Widget>(
        valueListenable: content,
        builder: (_, child, _) => child,
      ),
    );
  }
}

/// Signals readiness after a frame containing usable UI, not an empty shell.
class StartupReady extends StatefulWidget {
  const StartupReady({super.key, required this.ready, required this.child});
  final bool ready;
  final Widget child;

  @override
  State<StartupReady> createState() => _StartupReadyState();
}

class _StartupReadyState extends State<StartupReady> {
  bool _sent = false;

  @override
  Widget build(BuildContext context) {
    if (widget.ready && !_sent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.ready || _sent) return;
        _sent = true;
        unawaited(StartupAppearance.ready());
      });
    }
    return widget.child;
  }
}

class StartupScreen extends StatelessWidget {
  const StartupScreen({super.key, required this.appearance});
  final StartupAppearance appearance;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: appearance.theme(Brightness.light),
    darkTheme: appearance.theme(Brightness.dark),
    themeMode: appearance.mode,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    supportedLocales: AppLocalizations.delegate.supportedLocales,
    home: Builder(
      builder: (context) {
        final theme = Theme.of(context);
        final dark = theme.brightness == Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
            statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
            systemNavigationBarIconBrightness: dark
                ? Brightness.light
                : Brightness.dark,
          ),
          child: const Scaffold(
            body: SafeArea(child: Center(child: BrandMark(size: 168))),
          ),
        );
      },
    ),
  );
}
