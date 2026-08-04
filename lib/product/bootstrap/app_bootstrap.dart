import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application.dart';
import '../../clash/core.dart';
import '../../common/http.dart';
import '../../common/path.dart';
import '../../common/system.dart';
import '../../state.dart';
import '../diagnostics/diagnostic_recorder.dart';
import '../platform/product_platform_composition.dart';

class AppBootstrap {
  const AppBootstrap._();

  static Future<void> run() async {
    WidgetsFlutterBinding.ensureInitialized();
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
    await clashCore.preload();
    await globalState.initApp(version);
    await composition.bootstrap.initialize();

    HttpOverrides.global = FlClashHttpOverrides();
    runApp(const ProviderScope(child: Application()));
  }
}
