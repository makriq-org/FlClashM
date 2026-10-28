part of '../action.dart';

@Riverpod(keepAlive: true)
class ManagedSettingsAction extends _$ManagedSettingsAction {
  @override
  void build() {}

  void takeOver(String key) {
    ref
        .read(appSettingProvider.notifier)
        .update(
          (state) =>
              state.copyWith(ownedSettings: {...state.ownedSettings, key}),
        );
    _applyAccessControl(key);
  }

  void release(String key) {
    ref
        .read(appSettingProvider.notifier)
        .update(
          (state) => state.copyWith(
            ownedSettings: {...state.ownedSettings}..remove(key),
          ),
        );
    _reapply();
    _applyAccessControl(key);
  }

  void releaseAll() {
    final owned = ref.read(appSettingProvider).ownedSettings;
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(ownedSettings: const {}));
    _reapply();
    if (owned.contains(accessControlSettingKey)) {
      _applyAccessControl(accessControlSettingKey);
    }
  }

  void _reapply() {
    final profile = ref.read(currentProfileProvider);
    ref
        .read(profileHeadersActionProvider.notifier)
        .apply(profileHeaderSettingsOf(profile));
    unawaited(
      ref
          .read(profileSettingsActionProvider.notifier)
          .apply(profileSettingsSourceOf(profile)),
    );
  }

  /// Ownership of the access list changes the compiled plan, but the settings
  /// patch only carries `ownedSettings`; compile explicitly.
  void _applyAccessControl(String key) {
    if (key != accessControlSettingKey) {
      return;
    }
    unawaited(
      globalState.safeRun(
        () => ref.read(setupActionProvider.notifier).applyProfile(),
      ),
    );
  }
}
