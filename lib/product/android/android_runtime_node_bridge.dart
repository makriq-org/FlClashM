import 'package:flutter/services.dart';

abstract interface class RuntimeNodePlatformBridge {
  Future<bool> startNode({
    required String nodeId,
    required String executablePath,
    required String workingDirectory,
  });

  Future<void> stopNode({
    required String nodeId,
  });

  Future<DateTime?> readNodeStartTime({
    required String nodeId,
  });

  Future<void> saveColdStartNodes(String manifestJson);

  Future<void> clearColdStartNodes();
}

class AndroidRuntimeNodeBridge implements RuntimeNodePlatformBridge {
  const AndroidRuntimeNodeBridge();

  static const MethodChannel _channel =
      MethodChannel('com.follow.clashx/service');

  @override
  Future<bool> startNode({
    required String nodeId,
    required String executablePath,
    required String workingDirectory,
  }) async {
    final runTime = await _channel.invokeMethod<int>(
      'startRuntimeNode',
      <String, String>{
        'nodeId': nodeId,
        'path': executablePath,
        'workingDirectory': workingDirectory,
      },
    );
    return (runTime ?? 0) > 0;
  }

  @override
  Future<void> stopNode({
    required String nodeId,
  }) async {
    await _channel.invokeMethod(
      'stopRuntimeNode',
      <String, String>{
        'nodeId': nodeId,
      },
    );
  }

  @override
  Future<DateTime?> readNodeStartTime({
    required String nodeId,
  }) async {
    final runTime = await _channel.invokeMethod<int>(
      'getRuntimeNodeRunTime',
      <String, String>{
        'nodeId': nodeId,
      },
    );
    if (runTime == null || runTime <= 0) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(runTime);
  }

  @override
  Future<void> saveColdStartNodes(String manifestJson) async {
    await _channel.invokeMethod(
      'saveRuntimeNodesState',
      <String, String>{
        'nodes': manifestJson,
      },
    );
  }

  @override
  Future<void> clearColdStartNodes() async {
    await _channel.invokeMethod('clearRuntimeNodesState');
  }
}
