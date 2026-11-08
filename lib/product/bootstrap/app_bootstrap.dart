import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:rust_api/rust_api.dart';

import '../../application.dart';
import '../../bootstrap.dart';
import '../../clash/lib.dart';
import '../../common/common.dart';
import '../../widgets/brand_mark.dart';
import '../diagnostics/diagnostic_recorder.dart';
import 'backend_startup.dart';
import 'startup_appearance.dart';
import 'startup_screen.dart';

class AppBootstrap {
  static Future<void> run() async {
    WidgetsFlutterBinding.ensureInitialized();
    final appearance = await StartupAppearance.read();
    // System brightness can change while the assets load. Prepare both marks
    // before runApp so either first-frame selection is already compiled.
    final brightnesses = [
      if (appearance.mode != ThemeMode.dark) Brightness.light,
      if (appearance.mode != ThemeMode.light) Brightness.dark,
    ];
    await Future.wait(
      brightnesses.map(
        (brightness) =>
            SvgAssetLoader(BrandMark.assetFor(brightness)).loadBytes(null),
      ),
    );
    final content = ValueNotifier<Widget>(
      StartupScreen(appearance: appearance),
    );
    runApp(StartupHost(content: content, appearance: appearance));
    await productDiagnosticRecorder.initialize(await appPath.homeDirPath);
    productDiagnosticRecorder.installErrorHandlers();
    fileLogger.enable();
    await RustLib.init();
    final version = await system.init();
    ProviderContainer? container;
    await BackendStartup(
      initialize: () async {
        container = await bootstrap.init(version);
      },
      present: (startup) async {
        await loadStartupLocalizations();
        content.value = BackendStartupApp(
          startup: startup,
          exportLogs: exportStartupLogs,
          appearance: appearance,
        );
      },
      reconnect: clashLib?.reStart,
    ).run();
    request.attach(container!.read);
    StartupAppearance.bind(container!);
    content.value = UncontrolledProviderScope(
      container: container!,
      child: const Application(),
    );
  }
}
