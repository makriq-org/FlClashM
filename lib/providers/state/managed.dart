part of '../state.dart';

@Riverpod(keepAlive: true)
class ManagedClashKeys extends _$ManagedClashKeys {
  @override
  Set<String> build() => const {};

  void set(Set<String> keys) {
    if (!const SetEquality<String>().equals(keys, state)) {
      state = keys;
    }
  }
}

/// Package rules the current profile declares, whether or not the user has
/// taken them over. Both the screen and the managed-setting registry need the
/// declared rules: the registry keeps "return to provider" available.
final profileDeclaredAccessProvider =
    FutureProvider.autoDispose<AccessControlProps?>((ref) async {
      if (!system.isAndroid) {
        return null;
      }
      final profile = ref.watch(
        currentProfileProvider.select(
          (profile) => (profile?.id, profile?.lastUpdateDate),
        ),
      );
      final profileId = profile.$1;
      if (profileId == null) {
        return null;
      }
      return coreController.getProfileAccessControl(profileId);
    });

// Disposable presentation of credentials parsed by Go, without overwriting
// the user's saved account when the subscription temporarily owns the setting.
final profileDeclaredAuthenticationProvider =
    FutureProvider.autoDispose<AuthenticationProps>((ref) async {
      final profile = ref.watch(
        currentProfileProvider.select(
          (profile) => (profile?.id, profile?.lastUpdateDate),
        ),
      );
      return profile.$1 == null
          ? const AuthenticationProps()
          : coreController.getProfileAuthentication(profile.$1!);
    });

final effectiveAuthenticationProvider = Provider<AuthenticationProps>((ref) {
  if (ref.watch(settingLockedProvider('clash.authentication'))) {
    return ref.watch(profileDeclaredAuthenticationProvider).value ??
        const AuthenticationProps();
  }
  return ref.watch(
    networkSettingProvider.select((state) => state.authentication),
  );
});

/// Every setting the current subscription speaks for.
@riverpod
Set<String> managedSettings(Ref ref) {
  final switches = ref.watch(
    currentProfileProvider.select((profile) => profile?.headers.appSwitches),
  );
  final view = ref.watch(
    currentProfileProvider.select((profile) => profile?.headers.view),
  );
  final declaredAccess = ref.watch(profileDeclaredAccessProvider).value;
  return {
    if (switches != null) ...appSwitchSettings.values,
    ...managedViewKeysOf(view),
    ...ref.watch(managedClashKeysProvider),
    if (declaredAccess != null) accessControlSettingKey,
  };
}

@riverpod
bool settingOwned(Ref ref, String key) => ref.watch(
  appSettingProvider.select((state) => state.ownedSettings.contains(key)),
);

@riverpod
bool settingLocked(Ref ref, String key) =>
    ref.watch(managedSettingsProvider.select((keys) => keys.contains(key))) &&
    !ref.watch(settingOwnedProvider(key));

@riverpod
bool settingReleasable(Ref ref, String key) =>
    ref.watch(managedSettingsProvider.select((keys) => keys.contains(key))) &&
    ref.watch(settingOwnedProvider(key));

/// What the Access Control view shows: the profile rules while the profile
/// owns them, otherwise the manual editor state. Display filters stay local to
/// the editor in both cases.
final accessControlViewProvider = Provider.autoDispose<AccessControlProps>((
  ref,
) {
  final editor = ref.watch(accessControlStateProvider);
  final declared = ref.watch(profileDeclaredAccessProvider).value;
  if (declared == null ||
      ref.watch(settingOwnedProvider(accessControlSettingKey))) {
    return editor;
  }
  return declared.copyWith(
    sort: editor.sort,
    isFilterSystemApp: editor.isFilterSystemApp,
    isFilterNonInternetApp: editor.isFilterNonInternetApp,
  );
});
