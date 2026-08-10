import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application.dart';
import '../../common/http.dart';
import '../../common/path.dart';
import '../../common/system.dart';
import '../../pages/editor_window.dart';
import '../../state.dart';
import '../diagnostics/diagnostic_recorder.dart';
import '../platform/product_platform_composition.dart';

class AppBootstrap {
  const AppBootstrap._();

  static Future<void> run([List<String> args = const []]) async {
    WidgetsFlutterBinding.ensureInitialized();

    if (args.isNotEmpty && args.first == 'multi_window') {
      await runEditorSubWindow(args);
      return;
    }

    if (Platform.isWindows || Platform.isLinux) {
      DartPluginRegistrant.ensureInitialized();
    }

    await productDiagnosticRecorder.initialize(await appPath.homeDirPath);
    productDiagnosticRecorder.installErrorHandlers();

    await _runInitialized();
  }

  static Future<void> _runInitialized() async {
    final composition = productPlatformComposition;
    if (!composition.profile.supported) {
      throw UnsupportedError(composition.profile.unsupportedMessage);
    }

    final version = await system.version;
    await composition.bootstrap.preloadMihomo();
    await globalState.initApp(version);
    await composition.bootstrap.initialize(hostVersion: version);

    HttpOverrides.global = FlClashHttpOverrides();
    runApp(const ProviderScope(child: Application()));
  }
}
