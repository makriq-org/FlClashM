import 'dart:async';
import 'product/backend/backend_errors.dart';
import 'product/backend/backend_client.dart';
import 'package:flutter/material.dart' as material;

import 'package:flclashx/providers/app.dart';
import 'package:flclashx/providers/state.dart';
import 'package:flclashx/ui/ui.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'common/common.dart';
import 'enum/enum.dart';
import 'models/models.dart';

class GlobalState {
  static GlobalState? _instance;
  GlobalKey<NavigatorState> get navigatorKey => rootNavigatorKey;
  late String appEnv;
  late PackageInfo packageInfo;
  late Measure measure;
  late ProviderContainer container;
  bool needInitStatus = true;

  bool get isPre => appEnv != 'stable';

  bool get canCrashCore => canCrashCoreFor(isDebug: kDebugMode, appEnv: appEnv);

  @visibleForTesting
  static bool canCrashCoreFor({required bool isDebug, required String appEnv}) {
    return isDebug || appEnv == 'dev';
  }

  String? lastConfigMd5;
  ConfigCounts? lastConfigCounts;
  bool isAttach = false;

  GlobalState._internal();

  factory GlobalState() {
    _instance ??= GlobalState._internal();
    return _instance!;
  }

  /// The running core's version once asked, else the one the build was made with.
  String coreVersion = '';
  String get appVersionTag => appVersionDefine.isNotEmpty ? appVersionDefine : 'v${packageInfo.version}';
  bool get isStart => container.read(isStartProvider);
  Future<T?> showCommonDialog<T>({required Widget child,bool dismissible=true}) => material.showDialog<T>(context:navigatorKey.currentContext!,barrierDismissible:dismissible,builder:(_)=>child);
  Future<bool?> showMessage({String? title,required InlineSpan message,String? confirmText,bool cancelable=true})=>dialogs.showMessage(title:title??currentAppLocalizations.tip,message:message,confirmText:confirmText,cancelable:cancelable);
  void showNotifier(String message)=>dialogs.showNotifier(message);


  String get ua => packageInfo.uaWith(
    coreVersion.isNotEmpty ? coreVersion : coreVersionDefine,
  );

  Future<T?> loadingRun<T>(
    FutureOr<T> Function() futureFunction, {
    String? title,
    required LoadingTag? tag,
    bool silence = false,
  }) async {
    return globalState.safeRun(
      futureFunction,
      silence: silence,
      title: title,
      onStart: () {
        if (tag != null) {
          container.read(loadingProvider(tag).notifier).start();
        }
      },
      onEnd: () {
        if (tag != null) {
          container.read(loadingProvider(tag).notifier).stop();
        }
      },
    );
  }

  /// Concurrent [loadingRun]s would let the first to finish clear [tag].
  Future<void> batchRun<T>(
    List<T> items,
    Future<void> Function(T item) task, {
    required String Function(T item) label,
    required int concurrency,
    required LoadingTag? tag,
  }) async {
    final pool = TaskPool(concurrency);
    final failures = List<UpdatingMessage?>.filled(items.length, null);
    await loadingRun(
      () => Future.wait([
        for (final (index, item) in items.indexed)
          pool.run(() async {
            try {
              await task(item);
            } catch (e, s) {
              commonPrint.log(
                '${label(item)} ===> ${compactError(e)}, $s',
                logLevel: LogLevel.warning,
              );
              failures[index] = UpdatingMessage(
                label: label(item),
                message: userFacingErrorMessage(e, currentAppLocalizations),
              );
            }
          }),
      ]),
      tag: tag,
    );
    dialogs.showFailures(failures.nonNulls.toList());
  }

  Future<T?> safeRun<T>(
    FutureOr<T> Function() futureFunction, {
    String? title,
    VoidCallback? onStart,
    VoidCallback? onEnd,
    bool silence = true,
  }) async {
    try {
      onStart?.call();
      return await futureFunction();
    } catch (e, s) {
      commonPrint.log(
        title == null
            ? '${compactError(e)}, $s'
            : '$title ===> ${compactError(e)}, $s',
        logLevel: LogLevel.warning,
      );
      final message = e is BackendException || e is TimeoutException ? describeBackendError(e) : userFacingErrorMessage(e, currentAppLocalizations);
      if (silence) {
        dialogs.showNotifier(message, level: MessageLevel.error);
      } else {
        unawaited(
          dialogs.showMessage(
            title: title ?? currentAppLocalizations.tip,
            message: TextSpan(text: message),
          ),
        );
      }
      return null;
    } finally {
      onEnd?.call();
    }
  }
}

final globalState = GlobalState();
