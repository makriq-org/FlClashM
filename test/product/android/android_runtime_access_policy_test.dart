import 'dart:convert';

import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/android/android_runtime_access_policy.dart';
import 'package:flclashx/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = AndroidRuntimeAccessPolicy();

  group('AndroidRuntimeAccessPolicy', () {
    test('merges access control into vpn options on the client side', () {
      globalState.config = const Config(
        themeProps: defaultThemeProps,
        vpnProps: VpnProps(
          accessControl: AccessControl(
            enable: true,
            mode: AccessControlMode.acceptSelected,
            acceptList: ['com.example.app'],
          ),
        ),
      );

      final merged = policy.mergeVpnOptions('{"dns-hijack":["any:53"]}');
      final decoded = json.decode(merged) as Map<String, dynamic>;

      expect(decoded['dns-hijack'], ['any:53']);
      expect(decoded['accessControl'], {
        'mode': 'acceptSelected',
        'acceptList': ['com.example.app'],
        'rejectList': <String>[],
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
