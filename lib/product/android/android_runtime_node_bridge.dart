import 'dart:convert';

import 'package:flutter/services.dart';

class RuntimeNodePlanState {
  const RuntimeNodePlanState({
    required this.generation,
    required this.status,
    required this.message,
    required this.nodes,
    required this.optionalCheckActive,
  });

  factory RuntimeNodePlanState.fromJson(String source) {
    final value = json.decode(source) as Map<String, dynamic>;
    return RuntimeNodePlanState(
      generation: (value['generation'] as num?)?.toInt() ?? 0,
      status: value['status'] as String? ?? 'failed',
      message: value['message'] as String? ?? '',
      nodes: List<Map<String, dynamic>>.unmodifiable(
        (value['nodes'] as List? ?? const [])
            .map((item) => Map<String, dynamic>.from(item as Map)),
      ),
      optionalCheckActive: value['optionalCheckActive'] as bool? ?? false,
    );
  }

  final int generation;
  final String status;
  final String message;
  final List<Map<String, dynamic>> nodes;
  final bool optionalCheckActive;

  bool get isReady => status == 'ready' || status == 'idle';
}

abstract interface class RuntimeNodePlatformBridge {
  Future<RuntimeNodePlanState> applyPlan(List<Map<String, dynamic>> nodes);

  Future<RuntimeNodePlanState> readPlanState();

  Future<void> stopPlan();

  Future<void> saveColdStartNodes(String manifestJson);

  Future<void> clearColdStartNodes();
}

class AndroidRuntimeNodeBridge implements RuntimeNodePlatformBridge {
  const AndroidRuntimeNodeBridge();

  static const MethodChannel _channel =
      MethodChannel('com.makriq.flclash/service');

  @override
  Future<RuntimeNodePlanState> applyPlan(
    List<Map<String, dynamic>> nodes,
  ) async {
    final state = await _channel.invokeMethod<String>(
      'applyRuntimeNodePlan',
      <String, String>{
        'plan': json.encode(<String, dynamic>{'nodes': nodes}),
      },
    );
    return RuntimeNodePlanState.fromJson(state ?? '{}');
  }

  @override
  Future<RuntimeNodePlanState> readPlanState() async =>
      RuntimeNodePlanState.fromJson(
        await _channel.invokeMethod<String>('getRuntimeNodePlanState') ?? '{}',
      );

  @override
  Future<void> stopPlan() => _channel.invokeMethod<void>('stopRuntimeNodePlan');

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
