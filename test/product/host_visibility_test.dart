import 'package:flclashx/core/controller.dart';
import 'package:flclashx/manager/app_manager.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _IconSets extends IconSets {
  @override
  Stream<List<IconSet>> build() => Stream.value([]);
}

class _Core extends Fake implements CoreController {
  final visibility = <bool>[];

  @override
  void setHostActive(bool active) => visibility.add(active);
}

void main() {
  testWidgets(
    'a visible cold start enables backend events without a resume edge',
    (tester) async {
      final core = _Core();
      final container = ProviderContainer(
        overrides: [
          ...buildConfigOverrides(const Config(themeProps: ThemeProps())),
          currentProfileProvider.overrideWith((_) => null),
          coreHandlerProvider.overrideWithValue(core),
          iconSetsProvider.overrideWith(_IconSets.new),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const AppStateManager(child: SizedBox()),
        ),
      );
      expect(core.visibility, [true]);
      container.read(appVisibleProvider.notifier).value = false;
      await tester.pump();
      expect(core.visibility, [true, false]);
      container.read(appVisibleProvider.notifier).value = true;
      await tester.pump();
      expect(core.visibility, [true, false, true]);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
