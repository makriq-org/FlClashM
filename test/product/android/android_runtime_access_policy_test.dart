import 'dart:convert';

import 'package:flclashm/enum/enum.dart';
import 'package:flclashm/models/models.dart';
import 'package:flclashm/product/android/android_runtime_access_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = AndroidRuntimeAccessPolicy();

  group('AndroidRuntimeAccessPolicy', () {
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
