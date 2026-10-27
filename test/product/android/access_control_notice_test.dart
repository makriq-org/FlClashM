import 'package:flclashx/product/widgets/access_control_notice.dart';
import 'package:flclashx/ui/icons/icons.dart';
import 'package:flclashx/ui/ui.dart';
import 'package:flclashx/widgets/managed_setting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_app.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('managed and warning captions use app styles in $brightness', (
      tester,
    ) async {
      final theme = ThemeData(brightness: brightness);
      await tester.pumpWidget(
        TestApp(
          theme: theme,
          child: const Scaffold(
            body: Column(
              children: [
                ManagedSettingsMessage(message: 'Profile controls this'),
                ProductAccessControlNotice(message: 'VPN state unavailable'),
              ],
            ),
          ),
        ),
      );
      final managed = tester.widget<Text>(find.text('Profile controls this'));
      final warning = tester.widget<Text>(find.text('VPN state unavailable'));
      final context = tester.element(find.text('Profile controls this'));
      expect(managed.style, context.listCaptionStyle);
      expect(warning.style?.color, Theme.of(context).colorScheme.warning);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is GlyphIcon && widget.glyph == AppGlyphs.info,
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) => widget is GlyphIcon && widget.glyph == AppGlyphs.warning,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
