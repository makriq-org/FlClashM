import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
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
    await productDiagnosticRecorder.initialize(await appPath.homeDirPath);
    productDiagnosticRecorder.installErrorHandlers();
    fileLogger.enable();
    final appearance = await StartupAppearance.read();
    // Preload either palette in system mode, which can change mid-launch.
    for (final brightness in Brightness.values) {
      try {
        await SvgAssetLoader(BrandMark.assetFor(brightness)).loadBytes(null);
      } catch (error) {
        commonPrint.log('Could not preload the startup mark: $error');
      }
    }
    final content = ValueNotifier<Widget>(
      StartupScreen(appearance: appearance),
    );
    runApp(StartupHost(content: content, appearance: appearance));
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
    content.value = UncontrolledProviderScope(
      container: container!,
      child: const Application(),
    );
  }
}
