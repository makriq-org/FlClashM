import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../common/common.dart';
import '../../enum/enum.dart';
import '../../models/models.dart';
import '../android/android_runtime_access_policy.dart';
import '../compile/profile_split_tunneling.dart';
import '../compile/raw_profile.dart';
import '../runtime/engine_manager.dart';

@immutable
class AccessControlEditorState {
  AccessControlEditorState({
    this.query = '',
    required this.enabled,
    required this.mode,
    required this.showSystemApps,
    required this.showNoInternetApps,
    required Set<String> selectedPackages,
    required this.sort,
    this.dirty = false,
  }) : selectedPackages = Set.unmodifiable(selectedPackages);

  final String query;
  final bool enabled;
  final AccessControlMode mode;
  final bool showSystemApps;
  final bool showNoInternetApps;
  final Set<String> selectedPackages;
  final AccessSortType sort;
  final bool dirty;

  bool get isWhitelist => mode == AccessControlMode.acceptSelected;

  AccessControl toAccessControl() => AccessControl(
        enable: enabled,
        mode: mode,
        acceptList: isWhitelist ? selectedPackages.toList() : const [],
        rejectList: isWhitelist ? const [] : selectedPackages.toList(),
        sort: sort,
        isFilterSystemApp: !showSystemApps,
        isFilterNonInternetApp: !showNoInternetApps,
      );

  AccessControlEditorState copyWith({
    String? query,
    bool? enabled,
    AccessControlMode? mode,
    bool? showSystemApps,
    bool? showNoInternetApps,
    Set<String>? selectedPackages,
    AccessSortType? sort,
    bool? dirty,
  }) =>
      AccessControlEditorState(
        query: query ?? this.query,
        enabled: enabled ?? this.enabled,
        mode: mode ?? this.mode,
        showSystemApps: showSystemApps ?? this.showSystemApps,
        showNoInternetApps: showNoInternetApps ?? this.showNoInternetApps,
        selectedPackages: selectedPackages ?? this.selectedPackages,
        sort: sort ?? this.sort,
        dirty: dirty ?? this.dirty,
      );
}

/// Where the profile-managed access control shown in the Access Control view
/// is sourced from.
enum ProfileManagedAccessSource {
  /// Not profile-managed — the user's manual selection is editable.
  none,

  /// Derived from the current profile config while VPN is stopped, or used as
  /// a declared fallback when the applied snapshot is unavailable.
  profile,

  /// Read from the immutable options snapshot of the live Android VPN.
  appliedVpn,
}

enum ProfileManagedAccessNotice {
  none,
  drift,
  verificationUnavailable,
}

/// Immutable description of whether the Access Control view should present a
/// profile-managed (locked) state, which access control to display and whether
/// the running core diverges from what the profile config declares.
@immutable
class ProfileManagedAccess {
  const ProfileManagedAccess({
    required this.managed,
    required this.effectiveAccessControl,
    required this.source,
    required this.notice,
  });

  /// True when split tunneling is dictated by the profile/core and the manual
  /// editor should be locked.
  final bool managed;

  /// The access control to display, or null when [managed] is false.
  final AccessControl? effectiveAccessControl;

  final ProfileManagedAccessSource source;

  final ProfileManagedAccessNotice notice;

  bool get hasDrift => notice == ProfileManagedAccessNotice.drift;

  static const none = ProfileManagedAccess(
    managed: false,
    effectiveAccessControl: null,
    source: ProfileManagedAccessSource.none,
    notice: ProfileManagedAccessNotice.none,
  );
}

typedef LoadCurrentRawProfile = Future<RawProfile?> Function();
typedef ReadProfilesPath = Future<String> Function();
typedef ReadInstalledPackageNames = Future<List<String>> Function();

class ProfileManagedAccessController {
  ProfileManagedAccessController({
    required this.service,
    required this.loadCurrentRawProfile,
    required this.readProfilesPath,
    required this.readInstalledPackageNames,
  });

  final AccessControlService service;
  final LoadCurrentRawProfile loadCurrentRawProfile;
  final ReadProfilesPath readProfilesPath;
  final ReadInstalledPackageNames readInstalledPackageNames;

  int _generation = 0;
  bool _disposed = false;

  Future<ProfileManagedAccess?> refresh({
    required bool isRunning,
    required AccessControl? activeProfileAccessControl,
  }) async {
    final generation = ++_generation;
    final appliedSnapshotFuture = isRunning
        ? service.readAppliedProfileAccess()
        : Future.value(const ProfileAccessSnapshot.unavailable());
    final profileSnapshot = isRunning && activeProfileAccessControl != null
        ? ProfileAccessSnapshot.available(activeProfileAccessControl)
        : await service.readProfileConfigAccess(
            loadCurrentRawProfile: loadCurrentRawProfile,
            readProfilesPath: readProfilesPath,
            readInstalledPackageNames: readInstalledPackageNames,
          );
    final appliedSnapshot = await appliedSnapshotFuture;
    final resolved = service.resolveProfileManagedAccess(
      profileConfig: profileSnapshot,
      applied: appliedSnapshot,
      isRunning: isRunning,
    );
    if (_disposed || generation != _generation) {
      return null;
    }
    return resolved;
  }

  void dispose() {
    _disposed = true;
    _generation++;
  }
}

class AccessControlService {
  const AccessControlService({
    this.platform = const AndroidRuntimeAccessPolicy(),
  });

  final RuntimeAccessPlatformBridge platform;

  AccessControlEditorState createEditorState(AccessControl accessControl) =>
      AccessControlEditorState(
        enabled: accessControl.enable,
        mode: accessControl.mode,
        showSystemApps: !accessControl.isFilterSystemApp,
        showNoInternetApps: !accessControl.isFilterNonInternetApp,
        selectedPackages: accessControl.currentList.toSet(),
        sort: accessControl.sort,
      );

  AccessControlEditorState setQuery(
    AccessControlEditorState state,
    String query,
  ) {
    if (state.query == query) {
      return state;
    }
    return state.copyWith(query: query);
  }

  AccessControlEditorState setEnabled(
    AccessControlEditorState state, {
    required bool enabled,
  }) {
    if (state.enabled == enabled) {
      return state;
    }
    return state.copyWith(
      enabled: enabled,
      dirty: true,
    );
  }

  AccessControlEditorState togglePackage(
    AccessControlEditorState state,
    String packageName,
  ) {
    final selectedPackages = Set<String>.from(state.selectedPackages);
    if (selectedPackages.contains(packageName)) {
      selectedPackages.remove(packageName);
    } else {
      selectedPackages.add(packageName);
    }
    return state.copyWith(
      selectedPackages: selectedPackages,
      dirty: true,
    );
  }

  AccessControlEditorState switchMode(AccessControlEditorState state) =>
      state.copyWith(
        mode: state.isWhitelist
            ? AccessControlMode.rejectSelected
            : AccessControlMode.acceptSelected,
        selectedPackages: <String>{},
        dirty: true,
      );

  AccessControlEditorState toggleShowSystemApps(
    AccessControlEditorState state,
  ) =>
      state.copyWith(
        showSystemApps: !state.showSystemApps,
        dirty: true,
      );

  AccessControlEditorState toggleShowNoInternetApps(
    AccessControlEditorState state,
  ) =>
      state.copyWith(
        showNoInternetApps: !state.showNoInternetApps,
        dirty: true,
      );

  AccessControlEditorState clearSelection(AccessControlEditorState state) {
    if (state.selectedPackages.isEmpty) {
      return state;
    }
    return state.copyWith(
      selectedPackages: <String>{},
      dirty: true,
    );
  }

  VpnProps applyEditorState(
    VpnProps vpnProps,
    AccessControlEditorState editorState,
  ) =>
      vpnProps.copyWith(
        accessControl: editorState.toAccessControl(),
      );

  List<Package> filterPackages({
    required List<Package> packages,
    required AccessControlEditorState editorState,
  }) {
    final query = editorState.query.toLowerCase();
    final selectedPackages = editorState.selectedPackages;
    final filtered = packages.where((package) {
      if (!editorState.showSystemApps && package.system) {
        return false;
      }
      if (!editorState.showNoInternetApps && !package.internet) {
        return false;
      }
      if (query.isNotEmpty &&
          !package.label.toLowerCase().contains(query) &&
          !package.packageName.toLowerCase().contains(query)) {
        return false;
      }
      return true;
    }).toList();

    return filtered
      ..sort((a, b) {
        final selectedA = selectedPackages.contains(a.packageName);
        final selectedB = selectedPackages.contains(b.packageName);
        if (selectedA != selectedB) {
          return selectedA ? -1 : 1;
        }
        return _comparePackages(a, b, editorState.sort);
      });
  }

  int _comparePackages(Package a, Package b, AccessSortType sort) =>
      switch (sort) {
        AccessSortType.none =>
          a.label.toLowerCase().compareTo(b.label.toLowerCase()),
        AccessSortType.name => utils.sortByChar(
            utils.getPinyin(a.label),
            utils.getPinyin(b.label),
          ),
        AccessSortType.time => b.lastUpdateTime.compareTo(a.lastUpdateTime),
      };

  Future<List<Package>> ensurePackagesLoaded({
    required bool isMobileView,
    required List<Package> cachedPackages,
    required ValueChanged<List<Package>> onPackagesLoaded,
    Future<List<Package>> Function()? readPackages,
  }) async {
    if (isMobileView) {
      await Future.delayed(commonDuration);
    }

    if (cachedPackages.isNotEmpty) {
      return cachedPackages;
    }

    final packages = await (readPackages ?? platform.readPackages)();
    onPackagesLoaded(packages);
    return packages;
  }

  Future<ImageProvider?> readPackageIcon(String packageName) =>
      platform.readPackageIcon(packageName);

  AccessControl resolveVpnAccessControl({
    required AccessControl accessControl,
    AccessControl? profileAccessControl,
  }) =>
      profileAccessControl ?? accessControl;

  AccessControlEditorState resolveEditorState({
    required AccessControl accessControl,
    AccessControl? profileAccessControl,
    AccessControlEditorState? previousState,
  }) {
    final editorState = createEditorState(
      resolveVpnAccessControl(
        accessControl: accessControl,
        profileAccessControl: profileAccessControl,
      ),
    );
    if (previousState == null) {
      return editorState;
    }
    return editorState.copyWith(
      query: previousState.query,
      showSystemApps: previousState.showSystemApps,
      showNoInternetApps: previousState.showNoInternetApps,
    );
  }

  ProfileManagedAccessController createProfileManagedController({
    required LoadCurrentRawProfile loadCurrentRawProfile,
    required ReadProfilesPath readProfilesPath,
    required ReadInstalledPackageNames readInstalledPackageNames,
  }) =>
      ProfileManagedAccessController(
        service: this,
        loadCurrentRawProfile: loadCurrentRawProfile,
        readProfilesPath: readProfilesPath,
        readInstalledPackageNames: readInstalledPackageNames,
      );

  Future<ProfileAccessSnapshot> readProfileConfigAccess({
    required LoadCurrentRawProfile loadCurrentRawProfile,
    required ReadProfilesPath readProfilesPath,
    required ReadInstalledPackageNames readInstalledPackageNames,
  }) async {
    if (!platform.isAndroid) {
      return const ProfileAccessSnapshot.available(null);
    }
    try {
      final rawProfile = await loadCurrentRawProfile();
      if (rawProfile == null) {
        return const ProfileAccessSnapshot.available(null);
      }
      final rawConfig = rawProfile.config;
      final installedPackageNames =
          requiresInstalledPackageInventoryForProfileSplitTunneling(
        rawConfig,
        isAndroid: true,
      )
              ? await readInstalledPackageNames()
              : const <String>[];
      final resolved = await resolveAndroidProfileSplitTunneling(
        rawConfig: rawConfig,
        isAndroid: true,
        profilesPath: await readProfilesPath(),
        profileId: rawProfile.profile.id,
        installedPackageNames: installedPackageNames,
      );
      return ProfileAccessSnapshot.available(resolved.accessControl);
    } catch (_) {
      return const ProfileAccessSnapshot.unavailable();
    }
  }

  Future<ProfileAccessSnapshot> readAppliedProfileAccess() async {
    try {
      return await platform.readAppliedProfileAccess();
    } catch (_) {
      return const ProfileAccessSnapshot.unavailable();
    }
  }

  /// Hybrid resolver for the Access Control view.
  ///
  /// VPN off: the effective managed state comes from [profileConfig]. VPN on:
  /// it comes from the immutable Android VPN [applied] snapshot. Read failures
  /// remain distinct from an explicit snapshot with no profile package rule.
  ProfileManagedAccess resolveProfileManagedAccess({
    required ProfileAccessSnapshot profileConfig,
    required ProfileAccessSnapshot applied,
    required bool isRunning,
  }) {
    if (!isRunning) {
      if (!profileConfig.available) {
        return const ProfileManagedAccess(
          managed: false,
          effectiveAccessControl: null,
          source: ProfileManagedAccessSource.none,
          notice: ProfileManagedAccessNotice.verificationUnavailable,
        );
      }
      final configured = profileConfig.accessControl;
      return ProfileManagedAccess(
        managed: configured != null,
        effectiveAccessControl: configured,
        source: configured == null
            ? ProfileManagedAccessSource.none
            : ProfileManagedAccessSource.profile,
        notice: ProfileManagedAccessNotice.none,
      );
    }

    if (!applied.available) {
      final configured =
          profileConfig.available ? profileConfig.accessControl : null;
      return ProfileManagedAccess(
        managed: configured != null,
        effectiveAccessControl: configured,
        source: configured == null
            ? ProfileManagedAccessSource.none
            : ProfileManagedAccessSource.profile,
        notice: ProfileManagedAccessNotice.verificationUnavailable,
      );
    }

    final effective = applied.accessControl;
    final hasDrift = profileConfig.available &&
        !_sameNullableEffectiveAccess(
          profileConfig.accessControl,
          effective,
        );
    return ProfileManagedAccess(
      managed: effective != null,
      effectiveAccessControl: effective,
      source: ProfileManagedAccessSource.appliedVpn,
      notice: hasDrift
          ? ProfileManagedAccessNotice.drift
          : ProfileManagedAccessNotice.none,
    );
  }

  AccessControlEditorState reconcileManagedEditorState({
    required AccessControl manualAccessControl,
    required AccessControlEditorState previousState,
    required bool wasManaged,
    required ProfileManagedAccess managedAccess,
  }) {
    if (!wasManaged && !managedAccess.managed) {
      return previousState;
    }
    return resolveEditorState(
      accessControl: manualAccessControl,
      profileAccessControl: managedAccess.effectiveAccessControl,
      previousState: previousState,
    );
  }

  bool _sameNullableEffectiveAccess(AccessControl? a, AccessControl? b) {
    if (a == null || b == null) {
      return a == null && b == null;
    }
    return _sameEffectiveAccess(a, b);
  }

  bool _sameEffectiveAccess(AccessControl a, AccessControl b) {
    if (a.enable != b.enable || a.mode != b.mode) {
      return false;
    }
    final setA = a.currentList.toSet();
    final setB = b.currentList.toSet();
    return setA.length == setB.length && setA.containsAll(setB);
  }

  Future<bool> startVpn({required AccessControl accessControl}) =>
      platform.startVpn(accessControl: accessControl);

  Future<void> stopVpn() => platform.stopVpn();

  Future<ResolvedTunAccess> resolveRuntimeAccess({
    required bool requestedTunEnable,
    required bool realTunEnable,
    required Future<void> Function() onAuthorizeRestart,
    required ValueChanged<bool> onResolvedTunEnable,
    Future<AuthorizeCode> Function()? authorizeCore,
  }) =>
      platform.resolveTunAccess(
        requestedTunEnable: requestedTunEnable,
        realTunEnable: realTunEnable,
        onAuthorizeRestart: onAuthorizeRestart,
        onResolvedTunEnable: onResolvedTunEnable,
        authorizeCore: authorizeCore,
      );
}
