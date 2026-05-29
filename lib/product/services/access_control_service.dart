import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../common/common.dart';
import '../../enum/enum.dart';
import '../../models/models.dart';
import '../android/android_runtime_access_policy.dart';
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
