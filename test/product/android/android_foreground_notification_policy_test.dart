import 'dart:convert';

import 'package:flclashm/enum/enum.dart';
import 'package:flclashm/models/models.dart';
import 'package:flclashm/product/android/android_foreground_notification_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = AndroidForegroundNotificationPolicy();

  group('AndroidForegroundNotificationPolicy', () {
    test('uses provider display hints for foreground title', () {
      final profile = Profile(
        id: 'profile-1',
        label: 'Fallback Profile',
        autoUpdateDuration: Duration.zero,
        selectedMap: const {'Auto': 'Selected Proxy'},
        providerHeaders: {
          'flclashm-servicename': base64.encode(utf8.encode('Service Name')),
          'flclashm-serverinfo': base64.encode(utf8.encode('Auto')),
        },
      );

      final snapshot = policy.buildSnapshot(
        profile,
        groups: const [
          Group(
            type: GroupType.Selector,
            name: 'Auto',
            now: 'Runtime Proxy',
          ),
        ],
      );

      expect(snapshot.profileName, 'Fallback Profile');
      expect(snapshot.serviceName, 'Service Name');
      expect(snapshot.serverName, 'Runtime Proxy');
      expect(snapshot.title, 'Service Name / Runtime Proxy');
    });

    test('falls back to first usable selected proxy', () {
      const profile = Profile(
        id: 'profile-2',
        label: 'Profile',
        autoUpdateDuration: Duration.zero,
        selectedMap: {
          'Proxy': 'DIRECT',
          'Auto': 'Node A',
        },
      );

      final snapshot = policy.buildSnapshot(profile);

      expect(snapshot.serviceName, isEmpty);
      expect(snapshot.serverName, 'Node A');
      expect(snapshot.title, 'Profile / Node A');
    });

    test('keeps explicit proxy-change semantics for the tracked server group',
        () {
      final profile = Profile(
        id: 'profile-3',
        label: 'Profile',
        autoUpdateDuration: Duration.zero,
        providerHeaders: {
          'flclashm-servicename': base64.encode(utf8.encode('Service Name')),
          'flclashm-serverinfo': base64.encode(utf8.encode('Auto')),
        },
      );

      expect(
        policy.buildTitleForProxyChange(
          profile,
          groupName: 'Fallback',
          proxyName: 'Node B',
        ),
        isNull,
      );

      expect(
        policy.buildTitleForProxyChange(
          profile,
          groupName: 'Auto',
          proxyName: 'Node B',
        ),
        'Service Name / Node B',
      );
    });
  });
}
