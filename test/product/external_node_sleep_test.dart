import 'dart:async';

import 'package:flclashx/common/compute.dart';
import 'package:flclashx/core/controller.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/backend/external_nodes.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/views/proxies/card.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

const _node = Proxy(name: 'SaluteJazz', type: 'Socks5');
const _remote = Proxy(name: 'Remote', type: 'VLESS');
const _url = 'https://www.gstatic.com/generate_204';

class _Core extends Fake implements CoreController {
  final calls = <String>[];
  final results = <Completer<Delay?>>[];

  @override
  Future<Delay?> getDelay(String url, String name, [Duration? timeout]) {
    calls.add(name);
    final result = Completer<Delay?>();
    results.add(result);
    return result.future;
  }

  void finish(int index, int value) => results[index].complete(
    Delay(name: calls[index], url: _url, value: value),
  );
}

void _project(
  ProviderContainer container, {
  String state = 'sleeping',
  bool awake = false,
  String profile = 'p',
  String applied = 'p',
  int generation = 1,
  int nodesGeneration = 1,
  int viewGeneration = 1,
  String instance = 'service',
  bool running = true,
}) {
  container
      .read(externalNodesProvider.notifier)
      .project(
        runtime: {
          'instanceId': instance,
          'appliedGeneration': generation,
          'nodesGeneration': nodesGeneration,
          'appliedRunning': running,
          'nodes': [
            {
              'nodeId': 'external-1',
              'name': _node.name,
              'state': state,
              'awake': awake,
            },
          ],
        },
        profileId: profile,
        appliedProfileId: applied,
        viewGeneration: viewGeneration,
      );
}

ProviderContainer _container(_Core core) {
  final container = ProviderContainer(
    overrides: [
      ...buildConfigOverrides(
        const Config(currentProfileId: 'p', themeProps: ThemeProps()),
      ),
      currentProfileProvider.overrideWith((_) => null),
      coreHandlerProvider.overrideWithValue(core),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test(
    'sleep is explicit and scoped to the applied plan and backend instance',
    () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      _project(c);
      final sleeping = c.read(externalNodesProvider);
      expect(sleeping.sleeping(_node.name), isTrue);
      final old = sleeping.stamp(_node.name);
      _project(c, state: 'running', awake: true);
      expect(c.read(externalNodesProvider).accepts(_node.name, old), isFalse);
      final running = c.read(externalNodesProvider).stamp(_node.name);
      _project(c, state: 'degraded', awake: true);
      expect(
        c.read(externalNodesProvider).accepts(_node.name, running),
        isTrue,
      );
      _project(c);
      _project(c, state: 'running', awake: true);
      expect(
        c.read(externalNodesProvider).accepts(_node.name, running),
        isFalse,
      );
      _project(c, profile: 'other');
      expect(c.read(externalNodesProvider).nodes, isEmpty);
      _project(c, nodesGeneration: 2);
      expect(c.read(externalNodesProvider).nodes, isEmpty);
      _project(c, viewGeneration: 2);
      expect(c.read(externalNodesProvider).nodes, isEmpty);
      _project(c, running: false);
      expect(c.read(externalNodesProvider).sleeping(_node.name), isTrue);
      _project(c, running: false, state: 'stopped');
      expect(c.read(externalNodesProvider).sleeping(_node.name), isFalse);
      _project(c, instance: 'replacement', state: 'running', awake: true);
      expect(
        c.read(externalNodesProvider).accepts(_node.name, running),
        isFalse,
      );
    },
  );

  testWidgets(
    'batch skips sleep, wake refreshes, awake failure stays a failure',
    (tester) async {
      final core = _Core();
      final c = _container(core);
      await tester.pumpWidget(
        UncontrolledProviderScope(container: c, child: const SizedBox()),
      );
      _project(c);
      final action = c.read(proxiesActionProvider.notifier);
      c
          .read(delayDataSourceProvider.notifier)
          .setDelay(const Delay(name: 'SaluteJazz', url: _url, value: 88));
      final batch = action.delayTest([_node, _remote]);
      expect(core.calls, [_remote.name]);
      core.finish(0, 42);
      await batch;
      expect(c.read(externalNodesProvider).sleeping(_node.name), isTrue);
      _project(c, state: 'running', awake: true);
      await tester.pump();
      expect(core.calls, [_remote.name, _node.name]);
      expect(c.read(delayDataSourceProvider)[_url]?[_node.name], isNull);
      core.finish(1, 91);
      await tester.pump(const Duration(seconds: 1));
      expect(c.read(delayDataSourceProvider)[_url]?[_node.name], 91);
      final failed = action.proxyDelayTest(_node);
      _project(c, state: 'degraded', awake: true);
      core.finish(2, -1);
      await failed;
      expect(c.read(delayDataSourceProvider)[_url]?[_node.name], -1);
      _project(c);
      await tester.pump();
      expect(c.read(delayDataSourceProvider)[_url]?[_node.name], isNull);
      expect(c.read(pendingDelayTestsProvider), isEmpty);
      await tester.pump();
    },
  );

  testWidgets(
    'late and buffered measurements cannot survive sleep or a new plan',
    (tester) async {
      final core = _Core();
      final c = _container(core);
      await tester.pumpWidget(
        UncontrolledProviderScope(container: c, child: const SizedBox()),
      );
      _project(c, state: 'running', awake: true);
      final action = c.read(proxiesActionProvider.notifier);
      final old = action.proxyDelayTest(_node);
      _project(c);
      _project(c, state: 'running', awake: true);
      await tester.pump();
      expect(core.calls.length, 2);
      core.finish(1, 77);
      await tester.pump(const Duration(seconds: 1));
      expect(c.read(pendingDelayTestsProvider), isEmpty);
      core.finish(0, -1);
      await old;
      expect(c.read(delayDataSourceProvider)[_url]?[_node.name], 77);
      action.setDelay(const Delay(name: 'SaluteJazz', url: _url, value: 99));
      _project(c);
      await tester.pump(const Duration(seconds: 1));
      expect(c.read(delayDataSourceProvider)[_url]?[_node.name], isNull);
      final remote = action.proxyDelayTest(_remote);
      _project(c, generation: 2, nodesGeneration: 2, viewGeneration: 2);
      core.finish(2, 10);
      await remote;
      expect(c.read(delayDataSourceProvider)[_url]?[_remote.name], isNull);
      await tester.pump();
    },
  );

  testWidgets('wake measurement waits for a coherent committed plan', (
    tester,
  ) async {
    final core = _Core();
    final c = _container(core);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: const SizedBox()),
    );
    _project(c);
    c.read(proxiesActionProvider);
    _project(
      c,
      state: 'starting',
      awake: true,
      generation: 2,
      nodesGeneration: 2,
      viewGeneration: 1,
    );
    await tester.pump();
    expect(core.calls, isEmpty);
    _project(
      c,
      state: 'running',
      awake: true,
      generation: 2,
      nodesGeneration: 2,
      viewGeneration: 2,
    );
    await tester.pump();
    expect(core.calls, [_node.name]);
    core.finish(0, 88);
    await tester.pump(const Duration(seconds: 1));
    expect(c.read(delayDataSourceProvider)[_url]?[_node.name], 88);
    await tester.pump();
  });

  testWidgets(
    'card shows plain neutral sleep text over cached delay and pending test',
    (tester) async {
      final c = _container(_Core());
      globalState.container = c;
      _project(c);
      c
          .read(delayDataSourceProvider.notifier)
          .setDelay(const Delay(name: 'SaluteJazz', url: _url, value: -1));
      c
          .read(pendingDelayTestsProvider.notifier)
          .apply(
            acquired: [delayTestKey(_url, _node.name)],
            started: [delayTestKey(_url, _node.name)],
          );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const TestApp(
            locale: Locale('ru'),
            includeNavigatorKey: false,
            child: SizedBox(
              width: 250,
              child: ProxyCard(
                groupName: 'PROXY',
                proxy: _node,
                groupType: GroupType.Selector,
                type: ProxyCardType.compact,
                testUrl: _url,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Спит'), findsOneWidget);
      final text = tester.widget<Text>(find.text('Спит'));
      final context = tester.element(find.text('Спит'));
      expect(text.style?.color, Theme.of(context).colorScheme.onSurfaceVariant);
      expect(find.textContaining('ms'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
