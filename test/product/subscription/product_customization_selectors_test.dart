import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('explicit user override disables advisory new dashboard mode', () {
    final profiles = [
      const Profile(
        id: 'profile-1',
        autoUpdateDuration: Duration.zero,
        providerHeaders: {'flclashm-newboard': 'true'},
      ),
    ];
    final container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWithBuild((_, _) => profiles),
        currentProfileIdProvider.overrideWithBuild((_, _) => 'profile-1'),
        appSettingProvider.overrideWithBuild(
          (_, _) => const AppSettingProps(newDashboard: false),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(effectiveNewDashboardProvider), isFalse);
    expect(container.read(dashboardEditingLockedProvider), isFalse);
  });

  test('denywidgets still locks dashboard editing independently', () {
    final profiles = [
      const Profile(
        id: 'profile-1',
        autoUpdateDuration: Duration.zero,
        providerHeaders: {
          'flclashm-newboard': 'true',
          'flclashm-denywidgets': 'true',
        },
      ),
    ];
    final container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWithBuild((_, _) => profiles),
        currentProfileIdProvider.overrideWithBuild((_, _) => 'profile-1'),
        appSettingProvider.overrideWithBuild(
          (_, _) => const AppSettingProps(newDashboard: false),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(effectiveNewDashboardProvider), isFalse);
    expect(container.read(dashboardEditingLockedProvider), isTrue);
  });
}
