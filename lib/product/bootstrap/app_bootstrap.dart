import 'dart:async';
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
import '../services/app_update_service.dart';
import '../services/desktop_app_update_bridge.dart';

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
    if (Platform.isWindows) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_showWindowsInstallResult(composition));
      });
    }
  }

  static Future<void> _showWindowsInstallResult(
    ProductPlatformComposition composition,
  ) async {
    final update = composition.services.appUpdate;
    if (update is! AppUpdateService ||
        update.platform is! DesktopAppUpdateBridge) {
      return;
    }
    final result = await (update.platform as DesktopAppUpdateBridge)
        .consumePendingInstallResult();
    if (result == null) return;
    final message = switch (result.outcome) {
      WindowsInstallOutcome.success =>
        'FlClashM обновлён до версии ${result.version}.',
      WindowsInstallOutcome.failed =>
        'Не удалось установить FlClashM ${result.version}. Предыдущая версия восстановлена.',
      WindowsInstallOutcome.rollbackFailed =>
        'Не удалось восстановить FlClashM после ошибки установки. Переустановите приложение.',
    };
    globalState.showNotifier(message);
  }
}
