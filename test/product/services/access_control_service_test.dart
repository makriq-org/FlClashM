// ignore_for_file: avoid_positional_boolean_parameters

import 'dart:async';
import 'dart:typed_data';

import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/android/android_runtime_access_policy.dart';
import 'package:flclashx/product/services/access_control_service.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRuntimeAccessPlatform implements RuntimeAccessPlatformBridge {
  _FakeRuntimeAccessPlatform({
    this.packages = const [],
    this.icon,
    this.appliedSnapshot = const ProfileAccessSnapshot.unavailable(),
    this.appliedSnapshotReader,
  });

  final List<Package> packages;
  final ImageProvider? icon;
  final ProfileAccessSnapshot appliedSnapshot;
  final Future<ProfileAccessSnapshot> Function()? appliedSnapshotReader;

  @override
  bool get isAndroid => true;

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
  Future<ProfileAccessSnapshot> readAppliedProfileAccess() async {
    appliedOptionsReadCalls++;
    return appliedSnapshotReader?.call() ?? appliedSnapshot;
  }
}

void main() {
  group('AccessControlSaveGuard', () {
    const manual = AccessControl(enable: true, rejectList: ['com.manual']);
    const profile = AccessControl(enable: true, rejectList: ['com.profile']);

    test('protects an unsaved manual draft during a refresh', () {
      final guard = AccessControlSaveGuard();
      expect(guard.shouldConfirmExit(draftChanged: true), isTrue);
      expect(guard.shouldConfirmExit(draftChanged: false), isFalse);
    });

    test('retains manual edits across managed updates and restores them', () {
      final draft = ManualAccessDraft();
      expect(draft.value, isNull);
      draft.suspend(manual);
      draft.suspend(profile);
      expect(draft.value, manual);
      expect(AccessControlSaveGuard().shouldConfirmExit(draftChanged: draft.value != const AccessControl()), isTrue);
      expect(draft.restore(const AccessControl()), manual);
      expect(draft.value, isNull);
      expect(draft.restore(profile), profile);
    });

    test('rejects a confirmation after ownership refresh or draft replacement', () {
      final guard = AccessControlSaveGuard();
      final ticket = guard.capture(manual);
      expect(guard.permits(ticket, currentDraft: manual, managed: false, resolving: false), isTrue);
      expect(guard.permits(ticket, currentDraft: profile, managed: false, resolving: false), isFalse);
      expect(guard.permits(ticket, currentDraft: manual, managed: true, resolving: false), isFalse);
      expect(guard.permits(ticket, currentDraft: manual, managed: false, resolving: true), isFalse);
      guard.invalidate();
      expect(guard.permits(ticket, currentDraft: manual, managed: false, resolving: false), isFalse);
      final fresh = guard.capture(manual);
      expect(guard.permits(fresh, currentDraft: manual, managed: false, resolving: false), isTrue);
    });
  });

  group('Android applied VPN options', () {
    test(
      'reads profile include and exclude lists from the Android snapshot',
      () async {
        final include = await AndroidRuntimeAccessPolicy(
          appliedOptionsReader: () async =>
              '{"includePackage":["com.android.chrome"],"excludePackage":null}',
        ).readAppliedProfileAccess();
        expect(include.available, isTrue);
        expect(include.accessControl?.mode, AccessControlMode.acceptSelected);
        expect(include.accessControl?.acceptList, ['com.android.chrome']);

        final exclude = await AndroidRuntimeAccessPolicy(
          appliedOptionsReader: () async =>
              '{"includePackage":null,"excludePackage":["com.android.chrome"]}',
        ).readAppliedProfileAccess();
        expect(exclude.available, isTrue);
        expect(exclude.accessControl?.mode, AccessControlMode.rejectSelected);
        expect(exclude.accessControl?.rejectList, ['com.android.chrome']);
      },
    );

    test(
      'distinguishes missing and malformed snapshots from no profile rule',
      () async {
        for (final json in [
          '',
          '{"includePackage":[3]}',
          '{"includePackage":[],"excludePackage":[]}',
        ]) {
          final result = await AndroidRuntimeAccessPolicy(
            appliedOptionsReader: () async => json,
          ).readAppliedProfileAccess();
          expect(result.available, isFalse);
        }
        final result = await AndroidRuntimeAccessPolicy(
          appliedOptionsReader: () async =>
              '{"includePackage":null,"excludePackage":null}',
        ).readAppliedProfileAccess();
        expect(result.available, isTrue);
        expect(result.accessControl, isNull);
      },
    );
  });

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

      expect(filtered.map((item) => item.packageName).toList(), [
        'com.example.selected',
        'com.example.other',
      ]);
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

      final resolvedIcon = await service.readPackageIcon(
        'com.example.with.icon',
      );

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

    test('reads applied profile access through the platform bridge', () async {
      const applied = AccessControl(
        enable: true,
        mode: AccessControlMode.acceptSelected,
        acceptList: ['a'],
      );
      final platform = _FakeRuntimeAccessPlatform(
        appliedSnapshot: const ProfileAccessSnapshot.available(applied),
      );
      final service = AccessControlService(platform: platform);

      final snapshot = await service.readAppliedProfileAccess();

      expect(snapshot.available, isTrue);
      expect(snapshot.accessControl, applied);
      expect(platform.appliedOptionsReadCalls, 1);
    });

    test(
      'resolves declared profile access inside the product service',
      () async {
        final service = AccessControlService(
          platform: _FakeRuntimeAccessPlatform(),
        );
        final snapshot = await service.readProfileConfigAccess(
          readProfileAccessControl: () async => const AccessControl(
            enable: true,
            mode: AccessControlMode.acceptSelected,
            acceptList: ['com.example.app'],
          ),
        );

        expect(snapshot.available, isTrue);
        expect(snapshot.accessControl?.mode, AccessControlMode.acceptSelected);
        expect(snapshot.accessControl?.acceptList, ['com.example.app']);
      },
    );

    group('resolveProfileManagedAccess', () {
      const service = AccessControlService();
      const profileAccess = AccessControl(
        enable: true,
        mode: AccessControlMode.acceptSelected,
        acceptList: ['com.profile'],
      );

      test('is unmanaged with no profile config and nothing applied', () {
        final resolved = service.resolveProfileManagedAccess(
          profileConfig: const ProfileAccessSnapshot.available(null),
          applied: const ProfileAccessSnapshot.unavailable(),
          isRunning: false,
        );

        expect(resolved.managed, isFalse);
        expect(resolved.effectiveAccessControl, isNull);
        expect(resolved.source, ProfileManagedAccessSource.none);
        expect(resolved.hasDrift, isFalse);
        expect(resolved.notice, ProfileManagedAccessNotice.none);
      });

      test('uses profile config when VPN is off', () {
        final resolved = service.resolveProfileManagedAccess(
          profileConfig: const ProfileAccessSnapshot.available(profileAccess),
          applied: const ProfileAccessSnapshot.unavailable(),
          isRunning: false,
        );

        expect(resolved.managed, isTrue);
        expect(resolved.effectiveAccessControl, profileAccess);
        expect(resolved.source, ProfileManagedAccessSource.profile);
        expect(resolved.hasDrift, isFalse);
      });

      test('ignores applied options while VPN is off', () {
        final resolved = service.resolveProfileManagedAccess(
          profileConfig: const ProfileAccessSnapshot.available(profileAccess),
          applied: const ProfileAccessSnapshot.available(
            AccessControl(
              enable: true,
              mode: AccessControlMode.rejectSelected,
              rejectList: ['com.applied'],
            ),
          ),
          isRunning: false,
        );

        expect(resolved.source, ProfileManagedAccessSource.profile);
        expect(resolved.effectiveAccessControl, profileAccess);
        expect(resolved.hasDrift, isFalse);
      });

      test('prefers applied VPN snapshot while VPN is on', () {
        const applied = AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: ['com.profile'],
        );
        final resolved = service.resolveProfileManagedAccess(
          profileConfig: const ProfileAccessSnapshot.available(profileAccess),
          applied: const ProfileAccessSnapshot.available(applied),
          isRunning: true,
        );

        expect(resolved.managed, isTrue);
        expect(resolved.effectiveAccessControl, applied);
        expect(resolved.source, ProfileManagedAccessSource.appliedVpn);
        expect(resolved.hasDrift, isFalse);
      });

      test('flags drift when applied VPN diverges from profile config', () {
        final resolved = service.resolveProfileManagedAccess(
          profileConfig: const ProfileAccessSnapshot.available(profileAccess),
          applied: const ProfileAccessSnapshot.available(
            AccessControl(
              enable: true,
              mode: AccessControlMode.acceptSelected,
              acceptList: ['com.profile', 'com.extra'],
            ),
          ),
          isRunning: true,
        );

        expect(resolved.managed, isTrue);
        expect(resolved.source, ProfileManagedAccessSource.appliedVpn);
        expect(resolved.hasDrift, isTrue);
      });

      test('treats explicit applied no-rule as drift, not a read failure', () {
        final resolved = service.resolveProfileManagedAccess(
          profileConfig: const ProfileAccessSnapshot.available(profileAccess),
          applied: const ProfileAccessSnapshot.available(null),
          isRunning: true,
        );

        expect(resolved.source, ProfileManagedAccessSource.appliedVpn);
        expect(resolved.effectiveAccessControl, isNull);
        expect(resolved.managed, isFalse);
        expect(resolved.hasDrift, isTrue);
      });

      test('flags drift when applied VPN has a rule absent from config', () {
        const applied = AccessControl(
          enable: true,
          mode: AccessControlMode.rejectSelected,
          rejectList: ['com.applied'],
        );
        final resolved = service.resolveProfileManagedAccess(
          profileConfig: const ProfileAccessSnapshot.available(null),
          applied: const ProfileAccessSnapshot.available(applied),
          isRunning: true,
        );

        expect(resolved.managed, isTrue);
        expect(resolved.effectiveAccessControl, applied);
        expect(resolved.source, ProfileManagedAccessSource.appliedVpn);
        expect(resolved.hasDrift, isTrue);
      });

      test('falls back honestly when applied VPN snapshot is unavailable', () {
        final resolved = service.resolveProfileManagedAccess(
          profileConfig: const ProfileAccessSnapshot.available(profileAccess),
          applied: const ProfileAccessSnapshot.unavailable(),
          isRunning: true,
        );

        expect(resolved.source, ProfileManagedAccessSource.profile);
        expect(resolved.effectiveAccessControl, profileAccess);
        expect(
          resolved.notice,
          ProfileManagedAccessNotice.verificationUnavailable,
        );
      });

      test('preserves dirty manual editor state across unmanaged refresh', () {
        final previous = service
            .createEditorState(
              const AccessControl(
                enable: true,
                mode: AccessControlMode.rejectSelected,
                rejectList: ['com.before'],
              ),
            )
            .copyWith(selectedPackages: {'com.edited'}, dirty: true);

        final reconciled = service.reconcileManagedEditorState(
          manualAccessControl: const AccessControl(
            enable: true,
            mode: AccessControlMode.rejectSelected,
            rejectList: ['com.before'],
          ),
          previousState: previous,
          wasManaged: false,
          managedAccess: ProfileManagedAccess.none,
        );

        expect(reconciled, same(previous));
      });

      test(
        'managed controller discards a stale asynchronous refresh',
        () async {
          final first = Completer<ProfileAccessSnapshot>();
          final second = Completer<ProfileAccessSnapshot>();
          var call = 0;
          final platform = _FakeRuntimeAccessPlatform(
            appliedSnapshotReader: () =>
                call++ == 0 ? first.future : second.future,
          );
          final service = AccessControlService(platform: platform);
          final controller = service.createProfileManagedController(
            readProfileAccessControl: () async => null,
          );
          const declared = AccessControl(
            enable: true,
            mode: AccessControlMode.acceptSelected,
            acceptList: ['com.profile'],
          );
          const newer = AccessControl(
            enable: true,
            mode: AccessControlMode.rejectSelected,
            rejectList: ['com.newer'],
          );

          final staleFuture = controller.refresh(
            isRunning: true,
            activeProfileAccessControl: declared,
          );
          final currentFuture = controller.refresh(
            isRunning: true,
            activeProfileAccessControl: declared,
          );
          second.complete(const ProfileAccessSnapshot.available(newer));
          final current = await currentFuture;
          first.complete(const ProfileAccessSnapshot.available(declared));
          final stale = await staleFuture;

          expect(current?.effectiveAccessControl, newer);
          expect(stale, isNull);
          controller.dispose();
        },
      );
    });
  });
}
