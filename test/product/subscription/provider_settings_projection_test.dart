import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final prefix in ['flclashm', 'flclashx']) {
    for (final custom in ['', 'add', 'update']) {
      for (final override in [false, true]) {
        test(
          '$prefix custom=$custom override=$override preserves user settings',
          () async {
            final profile = Profile(
              id: 'subscription',
              autoUpdateDuration: Duration.zero,
              providerHeaders: {
                if (custom.isNotEmpty) '$prefix-custom': custom,
                '$prefix-settings': 'minimize,autorun,shadowstart,autostart,autoupdate,openlogs,closeconnections',
              },
            );
            final container = ProviderContainer(
              overrides: [
                profilesProvider.overrideWithBuild((_, _) => [profile]),
                currentProfileIdProvider.overrideWithBuild(
                  (_, _) => profile.id,
                ),
                appSettingProvider.overrideWithBuild(
                  (_, _) => AppSettingProps(
                    overrideProviderSettings: override,
                    minimizeOnExit: false,
                    autoLaunch: false,
                    silentLaunch: false,
                    autoRun: false,
                    autoCheckUpdate: false,
                    openLogs: false,
                    closeConnections: false,
                    ownedSettings: const {'app.closeConnections'},
                  ),
                ),
              ],
            );
            addTearDown(container.dispose);
            container.listen(appSettingProvider, (_, _) {});
            container
                .read(profileHeadersActionProvider.notifier)
                .apply(profileHeaderSettingsOf(profile));
            await container.pump();
            final settings = container.read(appSettingProvider);
            expect(settings.minimizeOnExit, !override);
            expect(settings.autoLaunch, !override);
            expect(settings.silentLaunch, !override);
            expect(settings.autoRun, !override);
            expect(settings.autoCheckUpdate, !override);
            expect(settings.openLogs, !override);
            expect(settings.closeConnections, isFalse);
          },
        );
      }
    }
  }
}
