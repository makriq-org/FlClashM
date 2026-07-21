import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application.dart';
import '../../clash/core.dart';
import '../../clash/lib.dart';
import '../../common/android.dart';
import '../../common/http.dart';
import '../../common/print.dart';
import '../../common/system.dart';
import '../../state.dart';
import '../android/android_entrypoint.dart';
import '../platform/platform_profile.dart';

class AppBootstrap {
  const AppBootstrap._();

  static Future<void> run() async {
    final bootstrapTimer = Stopwatch()..start();
    WidgetsFlutterBinding.ensureInitialized();

    if (!productPlatform.supported) {
      throw UnsupportedError(
        'FlClashM is Android-only. Host platform: ${productPlatform.hostPlatform.name}',
      );
    }

    globalState.corePreload = clashCore.preload();
    final version = await system.version;
    await globalState.initApp(version);
    await android?.init();
    await androidEntrypoint.init();
    unawaited(
      clashLib?.setCrashlytics(globalState.config.appSetting.crashlytics),
    );

    HttpOverrides.global = FlClashHttpOverrides();
    runApp(const ProviderScope(child: Application()));
    commonPrint.log(
      '[Perf] bootstrap.runAppMs=${bootstrapTimer.elapsedMilliseconds}',
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      commonPrint.log(
        '[Perf] bootstrap.firstFrameMs=${bootstrapTimer.elapsedMilliseconds}',
      );
    });
    unawaited(
      globalState.corePreload.then((_) {
        commonPrint.log(
          '[Perf] bootstrap.corePreloadMs=${bootstrapTimer.elapsedMilliseconds}',
        );
      }).catchError((Object error) {
        commonPrint.log('[Perf] bootstrap.corePreloadFailed=$error');
      }),
    );
  }
}
