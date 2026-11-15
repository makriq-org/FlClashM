import 'package:flclashx/core/controller.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/ui/ui.dart';
import 'package:flclashx/views/navigation.dart';
import 'package:flclashx/views/views.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

/// Counts the polls the live feed makes, so a hidden feed can be shown to stop.
class _Core extends Fake implements CoreController {
  int reads = 0;

  @override
  Future<List<TrackerInfo>> getConnections() async {
    reads++;
    return const [];
  }

  @override
  Future<void> closeConnections() async {}
}

void main() {
  testWidgets('the two feeds share one page and the hidden one stops polling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _Core();
    final container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(core),
        currentProfileProvider.overrideWith((_) => null),
        appSettingProvider.overrideWithBuild(
          (_, _) => const AppSettingProps(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(child: ConnectionFeedsView()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pump(const Duration(milliseconds: 1200));

    expect(find.byType(ConnectionsView), findsOneWidget);
    expect(find.byType(RequestsView), findsNothing);
    expect(container.read(appSettingProvider).requestFeed, RequestFeed.live);
    final liveReads = core.reads;
    expect(liveReads, greaterThan(0));

    // The title names the feed on screen and its menu switches to the other.
    await tester.tap(find.text('Live connections'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recent requests'));
    await tester.pumpAndSettle();

    expect(find.byType(RequestsView), findsOneWidget);
    expect(container.read(appSettingProvider).requestFeed, RequestFeed.recent);
    // The live feed stays mounted, so it keeps its list and scroll position.
    expect(
      find.byType(ConnectionsView, skipOffstage: false),
      findsOneWidget,
    );

    final hiddenReads = core.reads;
    await tester.pump(const Duration(seconds: 3));
    expect(core.reads, hiddenReads);

    final hiddenScope = tester.widget<PageActivityScope>(
      find
          .ancestor(
            of: find.byType(ConnectionsView, skipOffstage: false),
            matching: find.byType(PageActivityScope, skipOffstage: false),
          )
          .first,
    );
    expect(hiddenScope.isActive, isFalse);

    // Coming back does not rebuild the feed from scratch.
    await tester.tap(find.text('Recent requests'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live connections'));
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionsView), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  test('navigation offers the two feeds as one connections page', () {
    final labels = navigation
        .getItems(hasProxies: true)
        .map((item) => item.label);

    expect(labels, contains(PageLabel.connections));
    expect(labels, isNot(contains(PageLabel.requests)));
  });
}
