import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application.dart';
import '../../clash/core.dart';
import '../../clash/lib.dart';
import '../../common/android.dart';
import '../../common/http.dart';
import '../../common/path.dart';
import '../../common/system.dart';
import '../../state.dart';
import '../android/android_entrypoint.dart';
import '../diagnostics/diagnostic_recorder.dart';
import '../platform/platform_profile.dart';
import 'backend_startup.dart';

class AppBootstrap {
  const AppBootstrap._();

  static Future<void> run() async {
    WidgetsFlutterBinding.ensureInitialized();
    await productDiagnosticRecorder.initialize(await appPath.homeDirPath);
    productDiagnosticRecorder.installErrorHandlers();

    await _runInitialized();
  }

  static Future<void> _runInitialized() async {
    if (!productPlatform.supported) {
      throw UnsupportedError(
        'FlClashM is Android-only. Host platform: ${productPlatform.hostPlatform.name}',
      );
    }

    final version = await system.version;
    await clashCore.preload();
    // Without the backend there is no configuration to render; show a
    // recovery screen instead of a blank app until it becomes reachable.
    await BackendStartup(
      initialize: () => globalState.initApp(version),
      present: presentBackendStartup,
      reconnect: clashLib?.reStart,
    ).run();
    await android?.init();
    await androidEntrypoint.init();

    HttpOverrides.global = FlClashHttpOverrides();
    runApp(const ProviderScope(child: Application()));
  }
}
