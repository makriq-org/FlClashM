import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ProviderContainer containerWith(Map<String, String> headers) {
    final profile = Profile(
      id: 'subscription',
      autoUpdateDuration: Duration.zero,
      providerHeaders: headers,
    );
    return ProviderContainer(
      overrides: [
        profilesProvider.overrideWithBuild((_, _) => [profile]),
        currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
      ],
    );
  }

  test('a subscription sending hideip owns the setting while it says so', () {
    final container = containerWith({'flclashm-special': 'hideip'});
    addTearDown(container.dispose);

    expect(container.read(managedSettingsProvider), contains(hideIpSetting));
  });

  test('a subscription that stops sending hideip releases the setting', () {
    final container = containerWith({'flclashm-special': ''});
    addTearDown(container.dispose);

    expect(
      container.read(managedSettingsProvider),
      isNot(contains(hideIpSetting)),
    );
  });
}
