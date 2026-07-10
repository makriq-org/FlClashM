// ignore_for_file: avoid_positional_boolean_parameters

import 'dart:typed_data';

import 'package:flclashm/enum/enum.dart';
import 'package:flclashm/models/models.dart';
import 'package:flclashm/product/android/android_runtime_access_policy.dart';
import 'package:flclashm/product/runtime/engine_manager.dart';
import 'package:flclashm/product/services/access_control_service.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRuntimeAccessPlatform implements RuntimeAccessPlatformBridge {
  _FakeRuntimeAccessPlatform({
    this.packages = const [],
    this.icon,
  });

  final List<Package> packages;
  final ImageProvider? icon;

  AccessControl? lastStartAccessControl;
  String? lastIconPackageName;
  int packageReadCalls = 0;
  int stopCalls = 0;
  int resolveCalls = 0;

  @override
  Future<List<Package>> readPackages() async {
    packageReadCalls++;
    return packages;
  }

  @override
  Future<ImageProvider?> readPackageIcon(String packageName) async {
    lastIconPackageName = packageName;
    return icon;
  }

  @override
  String mergeVpnOptions(
    String optionsJson, {
    required AccessControl accessControl,
  }) =>
      optionsJson;

  @override
  Future<bool> startVpn({required AccessControl accessControl}) async {
    lastStartAccessControl = accessControl;
    return true;
  }

  @override
  Future<void> stopVpn() async {
    stopCalls++;
  }

  @override
  Future<ResolvedTunAccess> resolveTunAccess({
    required bool requestedTunEnable,
    required bool realTunEnable,
    required Future<void> Function() onAuthorizeRestart,
    required void Function(bool p1) onResolvedTunEnable,
    Future<AuthorizeCode> Function()? authorizeCore,
  }) async {
    resolveCalls++;
    onResolvedTunEnable(requestedTunEnable);
    return ResolvedTunAccess.proceed(enableTun: requestedTunEnable);
  }
}

void main() {
  group('AccessControlService', () {
    test('builds editor state and persists it back to vpn props', () {
      const service = AccessControlService();
      const accessControl = AccessControl(
        enable: true,
        mode: AccessControlMode.acceptSelected,
        acceptList: ['com.example.allowed'],
        sort: AccessSortType.time,
        isFilterSystemApp: false,
        isFilterNonInternetApp: false,
      );

      final editorState = service.createEditorState(accessControl);
      final updatedVpnProps = service.applyEditorState(
        const VpnProps(),
        editorState,
      );

      expect(editorState.enabled, isTrue);
      expect(editorState.mode, AccessControlMode.acceptSelected);
      expect(editorState.showSystemApps, isTrue);
      expect(editorState.showNoInternetApps, isTrue);
      expect(editorState.selectedPackages, {'com.example.allowed'});
      expect(updatedVpnProps.accessControl, accessControl);
    });

    test('filters packages with selection priority and persisted toggles', () {
      const service = AccessControlService();
      final editorState = service.setQuery(
        service.createEditorState(
          const AccessControl(
            enable: true,
            mode: AccessControlMode.rejectSelected,
            rejectList: ['com.example.selected'],
          ),
        ),
        'example',
      );

      final filtered = service.filterPackages(
        packages: const [
          Package(
            packageName: 'com.example.other',
            label: 'Other Example',
            system: false,
            internet: true,
            lastUpdateTime: 1,
          ),
          Package(
            packageName: 'com.example.selected',
            label: 'Selected Example',
            system: false,
            internet: true,
            lastUpdateTime: 2,
          ),
          Package(
            packageName: 'com.example.system',
            label: 'System Example',
            system: true,
            internet: true,
            lastUpdateTime: 3,
          ),
        ],
        editorState: editorState,
      );

      expect(
        filtered.map((item) => item.packageName).toList(),
        ['com.example.selected', 'com.example.other'],
      );
    });

    test('loads packages once and then serves cached values', () async {
      const expectedPackages = [
        Package(
          packageName: 'com.example.cached',
          label: 'Cached Example',
          system: false,
          internet: true,
          lastUpdateTime: 1,
        ),
      ];
      final platform = _FakeRuntimeAccessPlatform(packages: expectedPackages);
      final service = AccessControlService(platform: platform);
      var cachedPackages = const <Package>[];

      final firstLoad = await service.ensurePackagesLoaded(
        isMobileView: false,
        cachedPackages: cachedPackages,
        onPackagesLoaded: (packages) {
          cachedPackages = packages;
        },
      );
      final secondLoad = await service.ensurePackagesLoaded(
        isMobileView: false,
        cachedPackages: cachedPackages,
        onPackagesLoaded: (_) {},
      );

      expect(firstLoad, expectedPackages);
      expect(secondLoad, expectedPackages);
      expect(platform.packageReadCalls, 1);
    });

    test('delegates package icon lookup to the platform bridge', () async {
      final icon = MemoryImage(Uint8List.fromList([1, 2, 3]));
      final platform = _FakeRuntimeAccessPlatform(icon: icon);
      final service = AccessControlService(platform: platform);

      final resolvedIcon =
          await service.readPackageIcon('com.example.with.icon');

      expect(resolvedIcon, same(icon));
      expect(platform.lastIconPackageName, 'com.example.with.icon');
    });

    test('prioritizes profile-driven access control over manual state', () {
      const service = AccessControlService();
      const manualAccessControl = AccessControl(
        enable: true,
        mode: AccessControlMode.rejectSelected,
        rejectList: ['com.example.manual'],
      );
      const profileAccessControl = AccessControl(
        enable: true,
        mode: AccessControlMode.acceptSelected,
        acceptList: ['com.example.profile'],
      );

      final resolved = service.resolveVpnAccessControl(
        accessControl: manualAccessControl,
        profileAccessControl: profileAccessControl,
      );

      expect(resolved, profileAccessControl);
    });

    test(
      'builds editor state from profile-driven access control and keeps view filters',
      () {
        const service = AccessControlService();
        final previousState = service
            .createEditorState(
              const AccessControl(
                enable: true,
                mode: AccessControlMode.rejectSelected,
                rejectList: ['com.example.manual'],
                isFilterSystemApp: false,
                isFilterNonInternetApp: false,
              ),
            )
            .copyWith(
              query: 'telegram',
              showSystemApps: true,
              showNoInternetApps: true,
            );
        const profileAccessControl = AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: ['org.telegram.messenger'],
          sort: AccessSortType.time,
        );

        final resolved = service.resolveEditorState(
          accessControl: const AccessControl(
            enable: true,
            mode: AccessControlMode.rejectSelected,
            rejectList: ['com.example.manual'],
          ),
          profileAccessControl: profileAccessControl,
          previousState: previousState,
        );

        expect(resolved.mode, AccessControlMode.acceptSelected);
        expect(resolved.selectedPackages, {'org.telegram.messenger'});
        expect(resolved.query, 'telegram');
        expect(resolved.showSystemApps, isTrue);
        expect(resolved.showNoInternetApps, isTrue);
        expect(resolved.sort, AccessSortType.time);
      },
    );

    test('delegates runtime access orchestration to the platform bridge',
        () async {
      final platform = _FakeRuntimeAccessPlatform();
      final service = AccessControlService(platform: platform);
      final resolvedValues = <bool>[];
      const accessControl = AccessControl(
        enable: true,
        rejectList: ['com.example.blocked'],
      );

      final started = await service.startVpn(accessControl: accessControl);
      final resolved = await service.resolveRuntimeAccess(
        requestedTunEnable: true,
        realTunEnable: false,
        onAuthorizeRestart: () async {},
        onResolvedTunEnable: resolvedValues.add,
      );
      await service.stopVpn();

      expect(started, isTrue);
      expect(platform.lastStartAccessControl, accessControl);
      expect(platform.resolveCalls, 1);
      expect(resolved.enableTun, isTrue);
      expect(resolvedValues, [true]);
      expect(platform.stopCalls, 1);
    });
  });
}
