import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_api/rust_api.dart';

import '../../application.dart';
import '../../bootstrap.dart';
import '../../clash/lib.dart';
import '../../common/common.dart';
import '../diagnostics/diagnostic_recorder.dart';
import 'backend_startup.dart';

class AppBootstrap {
  static Future<void> run() async {
    WidgetsFlutterBinding.ensureInitialized();
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
      present: presentBackendStartup,
      reconnect: clashLib?.reStart,
    ).run();
    request.attach(container!.read);
    runApp(
      UncontrolledProviderScope(
        container: container!,
        child: const Application(),
      ),
    );
  }
}
