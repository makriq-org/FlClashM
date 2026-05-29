import 'package:flclashm/models/models.dart';
import 'package:flclashm/providers/providers.dart';
import 'package:flclashm/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    globalState.config = const Config(themeProps: defaultThemeProps);
  });

  tearDown(() {
    globalState.config = const Config(themeProps: defaultThemeProps);
  });

  test('explicit user override disables advisory new dashboard mode', () {
    globalState.config = const Config(
      themeProps: defaultThemeProps,
      appSetting: AppSettingProps(newDashboard: false),
      profiles: [
        Profile(
          id: 'profile-1',
          autoUpdateDuration: Duration.zero,
          providerHeaders: {
            'flclashm-newboard': 'true',
          },
        ),
      ],
      currentProfileId: 'profile-1',
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(effectiveNewDashboardProvider), isFalse);
    expect(container.read(dashboardEditingLockedProvider), isFalse);
  });

  test('denywidgets still locks dashboard editing independently', () {
    globalState.config = const Config(
      themeProps: defaultThemeProps,
      appSetting: AppSettingProps(newDashboard: false),
      profiles: [
        Profile(
          id: 'profile-1',
          autoUpdateDuration: Duration.zero,
          providerHeaders: {
            'flclashm-newboard': 'true',
            'flclashm-denywidgets': 'true',
          },
        ),
      ],
      currentProfileId: 'profile-1',
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(effectiveNewDashboardProvider), isFalse);
    expect(container.read(dashboardEditingLockedProvider), isTrue);
  });
}
