// ignore_for_file: avoid_positional_boolean_parameters

import 'dart:typed_data';

import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/android/android_runtime_access_policy.dart';
import 'package:flclashx/product/runtime/engine_manager.dart';
import 'package:flclashx/product/services/access_control_service.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRuntimeAccessPlatform implements RuntimeAccessPlatformBridge {
  _FakeRuntimeAccessPlatform({
    this.packages = const [],
    this.icon,
    this.appliedVpnOptions,
  });

  final List<Package> packages;
  final ImageProvider? icon;
  final AndroidVpnOptions? appliedVpnOptions;

  AccessControl? lastStartAccessControl;
  String? lastIconPackageName;
  int packageReadCalls = 0;
  int stopCalls = 0;
  int resolveCalls = 0;
  int appliedOptionsReadCalls = 0;

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
  Future<AndroidVpnOptions?> readAppliedVpnOptions() async {
    appliedOptionsReadCalls++;
    return appliedVpnOptions;
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

    test('reads applied vpn options through the platform bridge', () async {
      final platform = _FakeRuntimeAccessPlatform(
        appliedVpnOptions: _vpnOptions(includePackage: const ['a']),
      );
      final service = AccessControlService(platform: platform);

      final options = await service.readAppliedVpnOptions();

      expect(options?.includePackage, ['a']);
      expect(platform.appliedOptionsReadCalls, 1);
    });

    test('maps applied include/exclude packages to access control', () {
      const service = AccessControlService();

      final include = service.appliedAccessControlFromOptions(
        _vpnOptions(includePackage: const ['com.a', 'com.b']),
      );
      expect(include?.mode, AccessControlMode.acceptSelected);
      expect(include?.acceptList, ['com.a', 'com.b']);

      final exclude = service.appliedAccessControlFromOptions(
        _vpnOptions(excludePackage: const ['com.c']),
      );
      expect(exclude?.mode, AccessControlMode.rejectSelected);
      expect(exclude?.rejectList, ['com.c']);

      expect(service.appliedAccessControlFromOptions(_vpnOptions()), isNull);
      expect(service.appliedAccessControlFromOptions(null), isNull);
    });

    group('resolveProfileManagedAccess', () {
      const service = AccessControlService();
      const profileAccess = AccessControl(
        enable: true,
        mode: AccessControlMode.acceptSelected,
        acceptList: ['com.profile'],
      );

      test('is unmanaged with no profile config and nothing applied', () {
        final resolved = service.resolveProfileManagedAccess(
          profileConfigAccessControl: null,
          appliedAccessControl: null,
          isRunning: false,
        );

        expect(resolved.managed, isFalse);
        expect(resolved.effectiveAccessControl, isNull);
        expect(resolved.source, ProfileManagedAccessSource.none);
        expect(resolved.hasDrift, isFalse);
      });

      test('uses profile config when VPN is off', () {
        final resolved = service.resolveProfileManagedAccess(
          profileConfigAccessControl: profileAccess,
          appliedAccessControl: null,
          isRunning: false,
        );

        expect(resolved.managed, isTrue);
        expect(resolved.effectiveAccessControl, profileAccess);
        expect(resolved.source, ProfileManagedAccessSource.profile);
        expect(resolved.hasDrift, isFalse);
      });

      test('ignores applied options while VPN is off', () {
        final resolved = service.resolveProfileManagedAccess(
          profileConfigAccessControl: profileAccess,
          appliedAccessControl: const AccessControl(
            enable: true,
            mode: AccessControlMode.rejectSelected,
            rejectList: ['com.applied'],
          ),
          isRunning: false,
        );

        expect(resolved.source, ProfileManagedAccessSource.profile);
        expect(resolved.effectiveAccessControl, profileAccess);
        expect(resolved.hasDrift, isFalse);
      });

      test('prefers applied core options while VPN is on', () {
        const applied = AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: ['com.profile'],
        );
        final resolved = service.resolveProfileManagedAccess(
          profileConfigAccessControl: profileAccess,
          appliedAccessControl: applied,
          isRunning: true,
        );

        expect(resolved.managed, isTrue);
        expect(resolved.effectiveAccessControl, applied);
        expect(resolved.source, ProfileManagedAccessSource.appliedCore);
        expect(resolved.hasDrift, isFalse);
      });

      test('flags drift when running core diverges from profile config', () {
        final resolved = service.resolveProfileManagedAccess(
          profileConfigAccessControl: profileAccess,
          appliedAccessControl: const AccessControl(
            enable: true,
            mode: AccessControlMode.acceptSelected,
            acceptList: ['com.profile', 'com.extra'],
          ),
          isRunning: true,
        );

        expect(resolved.managed, isTrue);
        expect(resolved.source, ProfileManagedAccessSource.appliedCore);
        expect(resolved.hasDrift, isTrue);
      });

      test('falls back to profile config when running core reports nothing', () {
        final resolved = service.resolveProfileManagedAccess(
          profileConfigAccessControl: profileAccess,
          appliedAccessControl: null,
          isRunning: true,
        );

        expect(resolved.source, ProfileManagedAccessSource.profile);
        expect(resolved.effectiveAccessControl, profileAccess);
        expect(resolved.hasDrift, isFalse);
      });

      test('is managed by applied core even without profile config', () {
        const applied = AccessControl(
          enable: true,
          mode: AccessControlMode.rejectSelected,
          rejectList: ['com.applied'],
        );
        final resolved = service.resolveProfileManagedAccess(
          profileConfigAccessControl: null,
          appliedAccessControl: applied,
          isRunning: true,
        );

        expect(resolved.managed, isTrue);
        expect(resolved.effectiveAccessControl, applied);
        expect(resolved.source, ProfileManagedAccessSource.appliedCore);
        expect(resolved.hasDrift, isFalse);
      });
    });
  });
}

AndroidVpnOptions _vpnOptions({
  List<String> includePackage = const [],
  List<String> excludePackage = const [],
}) =>
    AndroidVpnOptions(
      enable: true,
      port: 7890,
      accessControl: null,
      allowBypass: true,
      systemProxy: true,
      bypassDomain: const [],
      ipv4Address: '',
      ipv6Address: '',
      dnsServerAddress: '',
      includePackage: includePackage,
      excludePackage: excludePackage,
    );
