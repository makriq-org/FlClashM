import 'package:flclashx/common/file_logger.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/state.dart';
import 'package:flutter/cupertino.dart';

class CommonPrint {

  factory CommonPrint() {
    _instance ??= CommonPrint._internal();
    return _instance!;
  }

  CommonPrint._internal();
  static CommonPrint? _instance;

  static const _levelPriority = {
    LogLevel.debug: 0,
    LogLevel.info: 1,
    LogLevel.warning: 2,
    LogLevel.error: 3,
    LogLevel.silent: 4,
    LogLevel.app: 0,
  };

  void log(String? text) {
    final payload = "[FlClashX] $text";
    debugPrint(payload);

    fileLogger.log(payload);

    if (!globalState.isInit) {
      return;
    }
    final configuredLevel = globalState.effectiveLogLevel.value;
    final threshold = LogLevel.values.where(
      (l) => l.name == configuredLevel,
    ).firstOrNull;
    if (threshold != null &&
        (_levelPriority[LogLevel.app] ?? 0) < (_levelPriority[threshold] ?? 0)) {
      return;
    }
    globalState.appController.addLog(
      Log.app(payload),
    );
  }
}

final commonPrint = CommonPrint();
