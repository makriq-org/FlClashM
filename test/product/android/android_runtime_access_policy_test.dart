import 'dart:convert';

import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/android/android_runtime_access_policy.dart';
import 'package:flclashx/product/runtime/product_runtime.dart';
import 'package:flclashx/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = AndroidRuntimeAccessPolicy();

  group('AndroidRuntimeAccessPolicy', () {
    test('reads an applied include snapshot without losing an empty mode',
        () async {
      final policy = AndroidRuntimeAccessPolicy(
        appliedOptionsReader: () async => '{"includePackage":[]}',
      );

      final snapshot = await policy.readAppliedProfileAccess();

      expect(snapshot.available, isTrue);
      expect(snapshot.accessControl?.mode, AccessControlMode.acceptSelected);
      expect(snapshot.accessControl?.acceptList, isEmpty);
    });

    test('distinguishes an applied no-rule snapshot from unavailability',
        () async {
      final availablePolicy = AndroidRuntimeAccessPolicy(
        appliedOptionsReader: () async => '{}',
      );
      final unavailablePolicy = AndroidRuntimeAccessPolicy(
        appliedOptionsReader: () async => '',
      );

      final available = await availablePolicy.readAppliedProfileAccess();
      final unavailable = await unavailablePolicy.readAppliedProfileAccess();

      expect(available.available, isTrue);
      expect(available.accessControl, isNull);
      expect(unavailable.available, isFalse);
    });

    test('rejects malformed or ambiguous applied package snapshots', () async {
      final malformedPolicy = AndroidRuntimeAccessPolicy(
        appliedOptionsReader: () async => '{"includePackage":[1]}',
      );
      final ambiguousPolicy = AndroidRuntimeAccessPolicy(
        appliedOptionsReader: () async =>
            '{"includePackage":[],"excludePackage":[]}',
      );

      expect(
        (await malformedPolicy.readAppliedProfileAccess()).available,
        isFalse,
      );
      expect(
        (await ambiguousPolicy.readAppliedProfileAccess()).available,
        isFalse,
      );
    });

    test('merges access control into vpn options on the client side', () {
      final merged = policy.mergeVpnOptions(
        '{"dns-hijack":["any:53"]}',
        accessControl: const AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: ['com.example.app'],
        ),
      );
      final decoded = json.decode(merged) as Map<String, dynamic>;

      expect(decoded['dns-hijack'], ['any:53']);
      expect(decoded['accessControl'], {
        'mode': 'acceptSelected',
        'acceptList': ['com.example.app'],
        'rejectList': <String>[],
      });
    });

    test('forces self package bypass when access control is disabled', () {
      const policy = AndroidRuntimeAccessPolicy(
        selfPackageNames: ['com.makriq.flclash.dev'],
      );

      final merged = policy.mergeVpnOptions(
        '{"dns-hijack":["any:53"]}',
        accessControl: const AccessControl(),
      );
      final decoded = json.decode(merged) as Map<String, dynamic>;

      expect(decoded['accessControl'], {
        'mode': 'rejectSelected',
        'acceptList': <String>[],
        'rejectList': ['com.makriq.flclash.dev'],
      });
    });

    test('keeps self package out of include mode', () {
      const policy = AndroidRuntimeAccessPolicy(
        selfPackageNames: ['com.makriq.flclash.dev'],
      );

      final merged = policy.mergeVpnOptions(
        '{"dns-hijack":["any:53"]}',
        accessControl: const AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: ['com.example.app', 'com.makriq.flclash.dev'],
        ),
      );
      final decoded = json.decode(merged) as Map<String, dynamic>;

      expect(decoded['accessControl'], {
        'mode': 'acceptSelected',
        'acceptList': ['com.example.app'],
        'rejectList': <String>[],
      });
    });

    test('falls back to reject mode when include mode only contains self', () {
      const policy = AndroidRuntimeAccessPolicy(
        selfPackageNames: ['com.makriq.flclash.dev'],
      );

      final merged = policy.mergeVpnOptions(
        '{"dns-hijack":["any:53"]}',
        accessControl: const AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: ['com.makriq.flclash.dev'],
        ),
      );
      final decoded = json.decode(merged) as Map<String, dynamic>;

      expect(decoded['accessControl'], {
        'mode': 'rejectSelected',
        'acceptList': <String>[],
        'rejectList': ['com.makriq.flclash.dev'],
      });
    });

    test('keeps self bypass when core reports an empty include list', () {
      const policy = AndroidRuntimeAccessPolicy(
        selfPackageNames: ['com.makriq.flclash.dev'],
      );

      final merged = policy.mergeVpnOptions(
        '{"includePackage":[]}',
        accessControl: const AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: <String>[],
        ),
      );
      final decoded = json.decode(merged) as Map<String, dynamic>;

      expect(decoded['includePackage'], isEmpty);
      expect(decoded['accessControl'], {
        'mode': 'rejectSelected',
        'acceptList': <String>[],
        'rejectList': ['com.makriq.flclash.dev'],
      });
    });

    test('adds self package to reject mode', () {
      const policy = AndroidRuntimeAccessPolicy(
        selfPackageNames: ['com.makriq.flclash.dev'],
      );

      final merged = policy.mergeVpnOptions(
        '{"dns-hijack":["any:53"]}',
        accessControl: const AccessControl(
          enable: true,
          mode: AccessControlMode.rejectSelected,
          rejectList: ['com.example.blocked'],
        ),
      );
      final decoded = json.decode(merged) as Map<String, dynamic>;

      expect(decoded['accessControl'], {
        'mode': 'rejectSelected',
        'acceptList': <String>[],
        'rejectList': ['com.example.blocked', 'com.makriq.flclash.dev'],
      });
    });

    test('hardens cold-start core state access control for every mode', () {
      final globalState = GlobalState()
        ..config = const Config(themeProps: defaultThemeProps)
        ..activeProfileAccessControlNotifier.value = null;

      final disabledState = globalState.getCoreState(
        profileAccessControl: const AccessControl(),
      );
      expect(
        disabledState.vpnProps.accessControl,
        const AccessControl(
          enable: true,
          mode: AccessControlMode.rejectSelected,
          rejectList: ['com.makriq.flclash', 'com.makriq.flclash.dev'],
        ),
      );

      final acceptState = globalState.getCoreState(
        profileAccessControl: const AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: ['com.example.app', 'com.makriq.flclash'],
        ),
      );
      expect(
        acceptState.vpnProps.accessControl,
        const AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: ['com.example.app'],
        ),
      );

      final acceptSelfOnlyState = globalState.getCoreState(
        profileAccessControl: const AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: ['com.makriq.flclash'],
        ),
      );
      expect(
        acceptSelfOnlyState.vpnProps.accessControl,
        const AccessControl(
          enable: true,
          mode: AccessControlMode.rejectSelected,
          rejectList: ['com.makriq.flclash', 'com.makriq.flclash.dev'],
        ),
      );

      final rejectState = globalState.getCoreState(
        profileAccessControl: const AccessControl(
          enable: true,
          mode: AccessControlMode.rejectSelected,
          rejectList: ['com.example.blocked'],
        ),
      );
      expect(
        rejectState.vpnProps.accessControl,
        const AccessControl(
          enable: true,
          mode: AccessControlMode.rejectSelected,
          rejectList: [
            'com.example.blocked',
            'com.makriq.flclash',
            'com.makriq.flclash.dev',
          ],
        ),
      );
    });

    test('applies self bypass idempotently', () {
      const selfPackageNames = [
        'com.makriq.flclash',
        'com.makriq.flclash.dev',
      ];
      const scenarios = [
        AccessControl(),
        AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: ['com.example.app', 'com.makriq.flclash'],
        ),
        AccessControl(
          enable: true,
          mode: AccessControlMode.rejectSelected,
          rejectList: ['com.example.blocked', 'com.makriq.flclash'],
        ),
      ];

      for (final scenario in scenarios) {
        final once = enforceSelfPackageBypass(
          scenario,
          selfPackageNames: selfPackageNames,
        );
        final twice = enforceSelfPackageBypass(
          once,
          selfPackageNames: selfPackageNames,
        );

        expect(twice, once);
      }
    });

    test('aborts and requests restart after successful authorization',
        () async {
      var restarted = false;
      final resolvedValues = <bool>[];

      final result = await policy.resolveTunAccess(
        requestedTunEnable: true,
        realTunEnable: false,
        onAuthorizeRestart: () async {
          restarted = true;
        },
        onResolvedTunEnable: resolvedValues.add,
        authorizeCore: () async => AuthorizeCode.success,
      );

      expect(result.shouldProceed, isFalse);
      expect(restarted, isTrue);
      expect(resolvedValues, isEmpty);
    });
  });
}
