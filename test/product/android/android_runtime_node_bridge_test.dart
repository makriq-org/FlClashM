import 'dart:convert';

import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.makriq.flclash/service');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'applyRuntimeNodePlan' => json.encode({
            'generation': 4,
            'status': 'ready',
            'message': '',
            'optionalCheckActive': true,
            'nodes': [
              {'nodeId': 'node-a', 'ready': true, 'reused': false},
            ],
          }),
        'getRuntimeNodePlanState' => json.encode({
            'generation': 4,
            'status': 'ready',
            'message': '',
            'optionalCheckActive': false,
            'nodes': const [],
          }),
        'stopRuntimeNodePlan' => true,
        'probeRuntimeNode' => true,
        'probeRuntimeNodes' => 2,
        _ => null,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('sends the complete runtime plan in one platform call', () async {
    const bridge = AndroidRuntimeNodeBridge();
    final state = await bridge.applyPlan([
      {
        'nodeId': 'node-a',
        'type': 'naiveproxy',
        'port': 35010,
      },
      {
        'nodeId': 'node-b',
        'type': 'olcrtc',
        'port': 35910,
      },
    ]);

    expect(state.isReady, isTrue);
    expect(state.optionalCheckActive, isTrue);
    expect(calls, hasLength(1));
    final arguments = calls.single.arguments as Map;
    final plan = json.decode(arguments['plan'] as String) as Map;
    expect(plan['nodes'], hasLength(2));
  });

  test('reads aggregate state and stops the plan with one call', () async {
    const bridge = AndroidRuntimeNodeBridge();

    final state = await bridge.readPlanState();
    await bridge.stopPlan();

    expect(state.generation, 4);
    expect(calls.map((call) => call.method), [
      'getRuntimeNodePlanState',
      'stopRuntimeNodePlan',
    ]);
  });

  test('delegates an isolated runtime-node probe to Android', () async {
    const bridge = AndroidRuntimeNodeBridge();

    expect(await bridge.probeNode({'nodeId': 'probe-a'}), isTrue);
    expect(calls.single.method, 'probeRuntimeNode');
    final arguments = calls.single.arguments as Map;
    expect(json.decode(arguments['node'] as String), {'nodeId': 'probe-a'});
  });

  test('delegates a bounded runtime-node batch probe to Android', () async {
    const bridge = AndroidRuntimeNodeBridge();

    expect(
      await bridge.probeNodes(
        [
          {'nodeId': 'probe-a'},
          {'nodeId': 'probe-b'},
          {'nodeId': 'probe-c'},
        ],
        concurrency: 2,
      ),
      2,
    );
    expect(calls.single.method, 'probeRuntimeNodes');
    final arguments = calls.single.arguments as Map;
    final request = json.decode(arguments['request'] as String) as Map;
    expect(request['nodes'], hasLength(3));
    expect(request['concurrency'], 2);
  });
}
