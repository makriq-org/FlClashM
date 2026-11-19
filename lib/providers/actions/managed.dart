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
  }

  /// Asks before the user takes [key] over from the subscription; true once
  /// it is theirs to change.
  Future<bool> confirmTakeOver(String key) async {
    if (!ref.read(settingLockedProvider(key))) {
      return true;
    }
    final agreed = await dialogs.showMessage(
      title: currentAppLocalizations.managedByProvider,
      message: TextSpan(text: currentAppLocalizations.managedByProviderTip),
      confirmText: currentAppLocalizations.takeOver,
    );
    if (agreed != true || !ref.mounted) {
      return false;
    }
    takeOver(key);
    return true;
  }

  /// For a change from the tray or a hotkey, which has nowhere to ask.
  void takeOverIfLocked(String key) {
    if (ref.read(settingLockedProvider(key))) {
      takeOver(key);
    }
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
  }

  void releaseAll() {
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(ownedSettings: const {}));
    _reapply();
  }

  /// The backend reapplies the current profile's headers once ownership
  /// changes; only the clash settings still need their UI-side replay.
  void _reapply() {
    final profile = ref.read(currentProfileProvider);
    unawaited(
      ref
          .read(profileSettingsActionProvider.notifier)
          .apply(profileSettingsSourceOf(profile)),
    );
  }
}
