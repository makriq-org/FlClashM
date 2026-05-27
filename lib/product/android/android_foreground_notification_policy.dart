import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../common/common.dart';
import '../../models/models.dart';
import '../../plugins/vpn.dart';

@immutable
class AndroidForegroundNotificationSnapshot {
  const AndroidForegroundNotificationSnapshot({
    required this.profileName,
    required this.serviceName,
    required this.serverName,
  });

  final String profileName;
  final String serviceName;
  final String serverName;

  String get displayName => serviceName.isNotEmpty ? serviceName : profileName;

  String get title =>
      serverName.isNotEmpty ? '$displayName / $serverName' : displayName;
}

class AndroidForegroundNotificationPolicy {
  const AndroidForegroundNotificationPolicy();

  AndroidForegroundNotificationSnapshot buildSnapshot(
    Profile? profile, {
    Iterable<Group> groups = const [],
  }) {
    if (profile == null) {
      return const AndroidForegroundNotificationSnapshot(
        profileName: appName,
        serviceName: '',
        serverName: '',
      );
    }

    final profileName = profile.label ?? profile.id;
    final serviceName = decodeProviderHeader(
      profile.providerHeaders['flclashx-servicename'],
    );
    final serverGroupName = decodeProviderHeader(
      profile.providerHeaders['flclashx-serverinfo'],
    );
    final serverName = _resolveServerName(
      profile: profile,
      groups: groups,
      serverGroupName: serverGroupName,
    );

    return AndroidForegroundNotificationSnapshot(
      profileName: profileName,
      serviceName: serviceName,
      serverName: serverName,
    );
  }

  String buildTitle(
    Profile? profile, {
    Iterable<Group> groups = const [],
  }) =>
      buildSnapshot(profile, groups: groups).title;

  Future<void> syncCurrentProfile({
    required Profile? profile,
    Iterable<Group> groups = const [],
  }) async {
    final snapshot = buildSnapshot(profile, groups: groups);
    await pushTitle(snapshot.title);
  }

  String? buildTitleForProxyChange(
    Profile? profile, {
    required String groupName,
    required String proxyName,
  }) {
    if (profile == null) {
      return appName;
    }

    final serverGroupName = decodeProviderHeader(
      profile.providerHeaders['flclashx-serverinfo'],
    );
    if (serverGroupName.isNotEmpty && groupName != serverGroupName) {
      return null;
    }

    final snapshot = buildSnapshot(profile);
    return AndroidForegroundNotificationSnapshot(
      profileName: snapshot.profileName,
      serviceName: snapshot.serviceName,
      serverName: proxyName,
    ).title;
  }

  Future<void> syncProxyChange({
    required Profile? profile,
    required String groupName,
    required String proxyName,
  }) async {
    final title = buildTitleForProxyChange(
      profile,
      groupName: groupName,
      proxyName: proxyName,
    );
    if (title == null || title.isEmpty) {
      return;
    }
    await pushTitle(title);
  }

  Future<void> pushTitle(String title) async {
    if (title.isEmpty) {
      return;
    }
    await vpn?.updateNotification(title: title);
  }

  String decodeProviderHeader(String? value) {
    if (value == null || value.isEmpty) {
      return '';
    }
    try {
      final normalized = base64.normalize(value);
      return utf8.decode(base64.decode(normalized)).trim();
    } catch (_) {
      return value.trim();
    }
  }

  String _resolveServerName({
    required Profile profile,
    required Iterable<Group> groups,
    required String serverGroupName,
  }) {
    if (serverGroupName.isNotEmpty) {
      final group = groups.toList().getGroup(serverGroupName);
      final serverName =
          group?.realNow ?? profile.selectedMap[serverGroupName] ?? '';
      if (_isUsableServerName(serverName)) {
        return serverName;
      }
    }

    for (final group in groups) {
      if (_isUsableServerName(group.realNow)) {
        return group.realNow;
      }
    }

    for (final entry in profile.selectedMap.entries) {
      if (_isUsableServerName(entry.value)) {
        return entry.value;
      }
    }

    return '';
  }

  bool _isUsableServerName(String value) =>
      value.isNotEmpty && value != 'DIRECT' && value != 'REJECT';
}
