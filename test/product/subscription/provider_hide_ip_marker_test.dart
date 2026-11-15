import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ProviderContainer containerFor(Profile profile, AppSettingProps settings) {
    final container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWithBuild((_, _) => [profile]),
        currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
        appSettingProvider.overrideWithBuild((_, _) => settings),
      ],
    );
    addTearDown(container.dispose);
    container.listen(appSettingProvider, (_, _) {});
    return container;
  }

  Profile profileSending(String special) => Profile(
    id: 'subscription',
    autoUpdateDuration: Duration.zero,
    providerHeaders: {'flclashm-special': special},
  );

  void apply(ProviderContainer container, Profile profile) {
    container
        .read(profileHeadersActionProvider.notifier)
        .apply(profileHeaderSettingsOf(profile));
  }

  test('the flag turns the setting on and marks it as the panel', () {
    final profile = profileSending('hideip');
    final container = containerFor(profile, const AppSettingProps());

    apply(container, profile);

    final settings = container.read(appSettingProvider);
    expect(settings.hideIp, isTrue);
    expect(settings.panelSetSettings, contains(hideIpSetting));
  });

  test('dropping the flag turns the setting back off', () {
    final profile = profileSending('');
    final container = containerFor(
      profile,
      const AppSettingProps(panelSetSettings: {hideIpSetting}),
    );

    apply(container, profile);

    final settings = container.read(appSettingProvider);
    expect(settings.hideIp, isFalse);
    expect(settings.panelSetSettings, isEmpty);
  });

  test('a setting the user owns keeps the marker until it is handed back', () {
    final profile = profileSending('');
    final container = containerFor(
      profile,
      const AppSettingProps(
        panelSetSettings: {hideIpSetting},
        ownedSettings: {hideIpSetting},
      ),
    );

    apply(container, profile);

    final settings = container.read(appSettingProvider);
    // The marker stays, so handing the setting back still clears what the
    // panel once set instead of leaving it on for good.
    expect(settings.panelSetSettings, contains(hideIpSetting));
  });

  test('the flag never overrides a setting the user owns', () {
    final profile = profileSending('hideip');
    final container = containerFor(
      profile,
      const AppSettingProps(ownedSettings: {hideIpSetting}),
    );

    apply(container, profile);

    final settings = container.read(appSettingProvider);
    expect(settings.hideIp, isFalse);
    expect(settings.panelSetSettings, isEmpty);
  });
}
