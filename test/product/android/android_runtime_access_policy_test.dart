import 'dart:convert';

import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/android/android_runtime_access_policy.dart';
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

    test('drops client-side access control when it is disabled', () {
      final merged = policy.mergeVpnOptions(
        '{"dns-hijack":["any:53"],"accessControl":{"mode":"rejectSelected","rejectList":["com.example.legacy"]}}',
        accessControl: const AccessControl(),
      );
      final decoded = json.decode(merged) as Map<String, dynamic>;

      expect(decoded.containsKey('accessControl'), isFalse);
    });

    test('keeps include mode package list untouched', () {
      final merged = policy.mergeVpnOptions(
        '{"dns-hijack":["any:53"]}',
        accessControl: const AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: ['com.example.app', 'com.makriq.flclash'],
        ),
      );
      final decoded = json.decode(merged) as Map<String, dynamic>;

      expect(decoded['accessControl'], {
        'mode': 'acceptSelected',
        'acceptList': ['com.example.app', 'com.makriq.flclash'],
        'rejectList': <String>[],
      });
    });

    test('keeps reject mode package list untouched', () {
      final merged = policy.mergeVpnOptions(
        '{"dns-hijack":["any:53"]}',
        accessControl: const AccessControl(
          enable: true,
          mode: AccessControlMode.rejectSelected,
          rejectList: ['com.example.blocked', 'com.makriq.flclash'],
        ),
      );
      final decoded = json.decode(merged) as Map<String, dynamic>;

      expect(decoded['accessControl'], {
        'mode': 'rejectSelected',
        'acceptList': <String>[],
        'rejectList': ['com.example.blocked', 'com.makriq.flclash'],
      });
    });

    test(
      'aborts and requests restart after successful authorization',
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
      },
    );
  });
}
