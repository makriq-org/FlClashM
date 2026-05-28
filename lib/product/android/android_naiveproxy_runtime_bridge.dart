import 'package:flutter/services.dart';

abstract interface class NaiveProxyRuntimePlatformBridge {
  Future<bool> startProcess({
    required String executablePath,
    required String workingDirectory,
  });

  Future<void> stopProcess();

  Future<DateTime?> readProcessStartTime();

  Future<void> clearColdStartState();
}

class AndroidNaiveProxyRuntimeBridge
    implements NaiveProxyRuntimePlatformBridge {
  const AndroidNaiveProxyRuntimeBridge();

  static const MethodChannel _channel =
      MethodChannel('com.follow.clashx/service');

  @override
  Future<bool> startProcess({
    required String executablePath,
    required String workingDirectory,
  }) async {
    final runTime = await _channel.invokeMethod<int>(
      'startNaiveProxy',
      <String, String>{
        'path': executablePath,
        'workingDirectory': workingDirectory,
      },
    );
    return (runTime ?? 0) > 0;
  }

  @override
  Future<void> stopProcess() async {
    await _channel.invokeMethod('stopNaiveProxy');
  }

  @override
  Future<DateTime?> readProcessStartTime() async {
    final runTime = await _channel.invokeMethod<int>('getNaiveProxyRunTime');
    if (runTime == null || runTime <= 0) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(runTime);
  }

  @override
  Future<void> clearColdStartState() async {
    await _channel.invokeMethod('clearQuickStartParams');
  }
}
