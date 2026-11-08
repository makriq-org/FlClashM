// Render real startup widgets without a device. Run explicitly with:
// flutter test tool/render_startup_test.dart --dart-define=FONT_DIR=<SDK>/bin/cache/artifacts/material_fonts
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flclashx/product/bootstrap/startup_appearance.dart';
import 'package:flclashx/product/bootstrap/startup_screen.dart';
import 'package:flclashx/widgets/brand_mark.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const fontDirectory = String.fromEnvironment('FONT_DIR');
    if (fontDirectory.isEmpty) {
      throw StateError('Pass FONT_DIR from your Flutter SDK');
    }
    final fonts = FontLoader('Roboto');
    for (final name in [
      'Roboto-Regular.ttf',
      'Roboto-Medium.ttf',
      'Roboto-Bold.ttf',
    ]) {
      fonts.addFont(
        File('$fontDirectory/$name').readAsBytes().then(ByteData.sublistView),
      );
    }
    await fonts.load();
  });
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('render ${mode.name} startup', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('ru');
      tester.platformDispatcher.localesTestValue = const [Locale('ru')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: StartupScreen(appearance: StartupAppearance(mode: mode)),
        ),
      );
      await tester.runAsync(
        () => SvgAssetLoader(
          BrandMark.assetFor(
            mode == ThemeMode.light ? Brightness.light : Brightness.dark,
          ),
        ).loadBytes(null),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 3);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('output/startup').create(recursive: true);
        await File('output/startup/startup-${mode.name}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
    });
  }
}
