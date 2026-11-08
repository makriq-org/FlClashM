import 'package:flclashx/product/bootstrap/startup_appearance.dart';
import 'package:flclashx/product/bootstrap/startup_screen.dart';
import 'package:flclashx/widgets/brand_mark.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ready UI replaces startup immediately', (tester) async {
    final content = ValueNotifier<Widget>(
      const StartupScreen(appearance: StartupAppearance()),
    );
    await tester.pumpWidget(StartupHost(content: content));
    content.value = const MaterialApp(home: Text('ready'));
    await tester.pump();
    expect(find.text('ready'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(StartupScreen), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    content.dispose();
  });

  test(
    'missing first-frame cache uses the shared application surface',
    () async {
      final appearance = await StartupAppearance.read();
      expect(appearance.mode, ThemeMode.system);
      for (final brightness in Brightness.values) {
        final theme = appearance.theme(brightness);
        expect(theme.brightness, brightness);
        expect(
          theme.scaffoldBackgroundColor,
          brightness == Brightness.light
              ? const Color(0xffeeedef)
              : const Color(0xff121315),
        );
      }
    },
  );

  test(
    'startup reads only the projected cache, including explicit light mode',
    () async {
      const channel = MethodChannel('com.makriq.flclash/startup_appearance');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            ..setMockMethodCallHandler(
              channel,
              (call) async => {'themeMode': 'light', 'pureBlack': true},
            );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final appearance = await StartupAppearance.read();
      expect(appearance.mode, ThemeMode.light);
      expect(
        appearance.theme(Brightness.light).scaffoldBackgroundColor,
        const Color(0xffeeedef),
      );
      expect(
        appearance.theme(Brightness.dark).scaffoldBackgroundColor,
        const Color(0xff000000),
      );
    },
  );

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('startup ${mode.name} shows only its themed vector mark', (
      tester,
    ) async {
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
      await tester.pump();
      expect(find.byType(BrandMark), findsOneWidget);
      expect(find.byType(Text), findsNothing);
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(Text), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final mark = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(
        (mark.bytesLoader as SvgAssetLoader).assetName,
        BrandMark.assetFor(
          mode == ThemeMode.light ? Brightness.light : Brightness.dark,
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
