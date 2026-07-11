import 'package:flutter/services.dart';

abstract interface class RuntimeNodePlatformBridge {
  Future<bool> startNode({
    required String nodeId,
    required String executablePath,
    required String workingDirectory,
    List<String> arguments = const [],
  });

  Future<void> stopNode({
    required String nodeId,
  });

  Future<DateTime?> readNodeStartTime({
    required String nodeId,
  });

  Future<String?> readNodeLastError({
    required String nodeId,
  });

  Future<void> saveColdStartNodes(String manifestJson);

  Future<void> clearColdStartNodes();
}

class AndroidRuntimeNodeBridge implements RuntimeNodePlatformBridge {
  const AndroidRuntimeNodeBridge();

  static const MethodChannel _channel =
      MethodChannel('com.makriq.flclash/service');

  @override
  Future<bool> startNode({
    required String nodeId,
    required String executablePath,
    required String workingDirectory,
    List<String> arguments = const [],
  }) async {
    final runTime = await _channel.invokeMethod<int>(
      'startRuntimeNode',
      <String, Object>{
        'nodeId': nodeId,
        'path': executablePath,
        'workingDirectory': workingDirectory,
        'arguments': arguments,
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
  Future<String?> readNodeLastError({
    required String nodeId,
  }) async {
    final message = await _channel.invokeMethod<String>(
      'getRuntimeNodeLastError',
      <String, String>{'nodeId': nodeId},
    );
    if (message == null || message.trim().isEmpty) {
      return null;
    }
    return message.trim();
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

class AndroidRuntimeNodeNativeLibraryBridge {
  const AndroidRuntimeNodeNativeLibraryBridge();

  static const MethodChannel _channel =
      MethodChannel('com.makriq.flclash/service');

  Future<String?> resolvePath(String fileName) async {
    final path = await _channel.invokeMethod<String>(
      'resolveNativeRuntimeLibrary',
      <String, String>{'name': fileName},
    );
    if (path == null || path.isEmpty) {
      return null;
    }
    return path;
  }
}
