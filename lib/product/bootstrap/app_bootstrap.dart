import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application.dart';
import '../../clash/core.dart';
import '../../clash/lib.dart';
import '../../common/android.dart';
import '../../common/http.dart';
import '../../common/system.dart';
import '../../state.dart';
import '../android/android_entrypoint.dart';
import '../platform/platform_profile.dart';

class AppBootstrap {
  const AppBootstrap._();

  static Future<void> run() async {
    WidgetsFlutterBinding.ensureInitialized();

    if (!productPlatform.supported) {
      throw UnsupportedError(
        'FlClashM is Android-only. Host platform: ${productPlatform.hostPlatform.name}',
      );
    }

    final version = await system.version;
    await clashCore.preload();
    await globalState.initApp(version);
    await android?.init();
    await androidEntrypoint.init();
    unawaited(
      clashLib?.setCrashlytics(globalState.config.appSetting.crashlytics),
    );

    HttpOverrides.global = FlClashHttpOverrides();
    runApp(const ProviderScope(child: Application()));
  }
}
