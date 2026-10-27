import 'dart:async';

import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/views/dashboard/widgets/profile_detail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _profileProvider = NotifierProvider<_Profile, Profile?>(_Profile.new);

class _Profile extends Notifier<Profile?> {
  @override
  Profile? build() =>
      const Profile(id: 'first', autoUpdateDuration: Duration.zero);
  void change(String id) =>
      state = Profile(id: id, autoUpdateDuration: Duration.zero);
}

class _Setup extends SetupAction {
  final requests = <String, Completer<String>>{};
  int requestCount = 0;
  (String?, int?) planRevision = ("service", 1);

  @override
  (String?, int?) get appliedPlanRevision => planRevision;

  @override
  Future<String> getProfileWithId(
    String profileId, {
    bool countsOnly = false,
    bool yaml = false,
  }) {
    if (!countsOnly) throw StateError('Expected counts-only request');
    requestCount++;
    return (requests[profileId] = Completer<String>()).future;
  }
}

class _CountsView extends ConsumerStatefulWidget {
  const _CountsView();
  @override
  ConsumerState<_CountsView> createState() => _CountsViewState();
}

class _CountsViewState extends ConsumerState<_CountsView>
    with ConfigCountsWatch<_CountsView> {
  @override
  Widget build(BuildContext context) {
    watchConfigCounts();
    return Text(
      configCountsFailed ? 'failed' : '${configCounts?.groups ?? '-'}',
    );
  }
}

void main() {
  testWidgets('switching profiles ignores an older counts response', (
    tester,
  ) async {
    final setup = _Setup();
    final container = ProviderContainer(
      overrides: [
        setupActionProvider.overrideWith(() => setup),
        currentProfileProvider.overrideWith(
          (ref) => ref.watch(_profileProvider),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: _CountsView()),
      ),
    );
    container.read(_profileProvider.notifier).change('second');
    await tester.pump();
    setup.requests['second']!.complete('{"groups":2,"proxies":3,"rules":4}');
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);
    setup.requests['first']!.complete('{"groups":9,"proxies":9,"rules":9}');
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('empty group projections do not repeatedly reload counts', (
    tester,
  ) async {
    final setup = _Setup();
    final container = ProviderContainer(
      overrides: [
        setupActionProvider.overrideWith(() => setup),
        currentProfileProvider.overrideWith(
          (ref) => ref.watch(_profileProvider),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: _CountsView()),
      ),
    );
    expect(setup.requestCount, 1);
    container.read(groupsProvider.notifier).value = <Group>[];
    await tester.pump();
    container.read(groupsProvider.notifier).value = <Group>[];
    await tester.pump();
    expect(setup.requestCount, 1);
    container.read(groupsProvider.notifier).value = [
      const Group(name: 'Proxy', type: GroupType.Selector),
    ];
    await tester.pump();
    expect(setup.requestCount, 2);
    container.read(groupsProvider.notifier).value = <Group>[];
    await tester.pump();
    expect(setup.requestCount, 3);
    container.read(groupsProvider.notifier).value = <Group>[];
    await tester.pump();
    expect(setup.requestCount, 3);
    setup.planRevision = ('service', 2);
    container.read(groupsProvider.notifier).value = <Group>[];
    await tester.pump();
    expect(setup.requestCount, 4);
  });
}
