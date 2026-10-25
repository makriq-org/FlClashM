import 'package:flutter/material.dart' as flutter;
import 'package:flutter_localizations/flutter_localizations.dart' as locales;
import 'package:material_ui/material_ui.dart' as ui;

const flutterMaterialLocalizations =
    locales.GlobalMaterialLocalizations.delegates;

/// The fork updater and platform pages use Flutter Material. Its inherited
/// types differ from material_ui's types, so provide both without a second app
/// or navigator. Colours follow the selected upstream theme.
class FlutterMaterialCompat extends ui.StatelessWidget {
  const FlutterMaterialCompat({super.key, required this.child});

  final ui.Widget child;

  @override
  ui.Widget build(ui.BuildContext context) {
    final colors = ui.Theme.of(context).colorScheme;
    final scheme =
        flutter.ColorScheme.fromSeed(
          seedColor: colors.primary,
          brightness: colors.brightness,
        ).copyWith(
          primary: colors.primary,
          onPrimary: colors.onPrimary,
          primaryContainer: colors.primaryContainer,
          onPrimaryContainer: colors.onPrimaryContainer,
          surface: colors.surface,
          onSurface: colors.onSurface,
          onSurfaceVariant: colors.onSurfaceVariant,
          error: colors.error,
          onError: colors.onError,
          errorContainer: colors.errorContainer,
          onErrorContainer: colors.onErrorContainer,
          outline: colors.outline,
        );
    return flutter.Theme(
      data: flutter.ThemeData(colorScheme: scheme, useMaterial3: true),
      child: child,
    );
  }
}
