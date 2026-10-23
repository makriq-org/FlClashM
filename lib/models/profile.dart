// ignore_for_file: invalid_annotation_target
import 'dart:convert';
import 'dart:typed_data';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:flclashx/product/backend/backend.dart';

import 'clash_config.dart';

part 'generated/profile.freezed.dart';
part 'generated/profile.g.dart';

typedef SelectedMap = Map<String, String>;

String? resolveFlClashProviderHeader(
  Map<String, String> headers,
  String suffix,
) {
  final normalizedSuffix = suffix.trim().toLowerCase();
  return headers['flclashm-$normalizedSuffix'] ??
      headers['flclashx-$normalizedSuffix'];
}

@freezed
abstract class SubscriptionInfo with _$SubscriptionInfo {
  const factory SubscriptionInfo({
    @Default(0) int upload,
    @Default(0) int download,
    @Default(0) int total,
    @Default(0) int expire,
  }) = _SubscriptionInfo;

  factory SubscriptionInfo.fromJson(Map<String, Object?> json) =>
      _$SubscriptionInfoFromJson(json);

  factory SubscriptionInfo.formHString(String? info) {
    if (info == null) return const SubscriptionInfo();
    final list = info.split(";");
    final map = <String, int?>{};
    for (final i in list) {
      final keyValue = i.trim().split("=");
      if (keyValue.length < 2) continue;
      map[keyValue[0]] = int.tryParse(keyValue[1]);
    }
    return SubscriptionInfo(
      upload: map["upload"] ?? 0,
      download: map["download"] ?? 0,
      total: map["total"] ?? 0,
      expire: map["expire"] ?? 0,
    );
  }
}

@freezed
abstract class Profile with _$Profile {
  const factory Profile({
    required String id,
    String? label,
    String? currentGroupName,
    @Default("") String url,
    DateTime? lastUpdateDate,
    required Duration autoUpdateDuration,
    SubscriptionInfo? subscriptionInfo,
    @Default(true) bool autoUpdate,
    @Default({}) SelectedMap selectedMap,
    @Default({}) Set<String> unfoldSet,
    @Default(OverrideData()) OverrideData overrideData,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(false)
    bool isUpdating,
    @Default({}) Map<String, String> providerHeaders,
  }) = _Profile;

  factory Profile.fromJson(Map<String, Object?> json) =>
      _$ProfileFromJson(json);

  factory Profile.normal({
    String? label,
    String url = '',
  }) =>
      Profile(
        label: label,
        url: url,
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        autoUpdateDuration: defaultUpdateDuration,
      );
}

@freezed
abstract class OverrideData with _$OverrideData {
  const factory OverrideData({
    @Default(false) bool enable,
    @Default(OverrideRule()) OverrideRule rule,
  }) = _OverrideData;

  factory OverrideData.fromJson(Map<String, Object?> json) =>
      _$OverrideDataFromJson(json);
}

extension OverrideDataExt on OverrideData {
  List<String> get runningRule {
    if (!enable) {
      return [];
    }
    return rule.rules.map((item) => item.value).toList();
  }
}

@freezed
abstract class OverrideRule with _$OverrideRule {
  const factory OverrideRule({
    @Default(OverrideRuleType.added) OverrideRuleType type,
    @Default([]) List<Rule> overrideRules,
    @Default([]) List<Rule> addedRules,
  }) = _OverrideRule;

  factory OverrideRule.fromJson(Map<String, Object?> json) =>
      _$OverrideRuleFromJson(json);
}

extension OverrideRuleExt on OverrideRule {
  List<Rule> get rules => switch (type == OverrideRuleType.override) {
        true => overrideRules,
        false => addedRules,
      };

  OverrideRule updateRules(List<Rule> Function(List<Rule> rules) builder) {
    if (type == OverrideRuleType.added) {
      return copyWith(addedRules: builder(addedRules));
    }
    return copyWith(overrideRules: builder(overrideRules));
  }
}

extension ProfilesExt on List<Profile> {
  Profile? getProfile(String? profileId) {
    final index = indexWhere((profile) => profile.id == profileId);
    return index == -1 ? null : this[index];
  }
}

extension ProfileExtension on Profile {
  ProfileType get type =>
      url.isEmpty == true ? ProfileType.file : ProfileType.url;

  bool get realAutoUpdate => url.isEmpty == true ? false : autoUpdate;

  Map<String, dynamic> toBackendMetadata() {
    final result = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(toJson())) as Map,
    );
    final date = lastUpdateDate;
    if (date != null) result['lastUpdateDate'] = date.toUtc().toIso8601String();
    return result;
  }

  Future<Uint8List> exportBytes() => backendClient.exportProfile(id);

  Future<Profile> _readBackend() async {
    final record = await backendClient.profile(id);
    final profile = Profile.fromJson(
      Map<String, dynamic>.from(record['metadata'] as Map),
    );
    return profile.copyWith(lastUpdateDate: profile.lastUpdateDate?.toLocal());
  }

  Future<Profile> update({
    bool shouldSendHeaders = true,
  }) async {
    final revision = backendClient.profileRevision(id);
    if (revision == 0) {
      await backendClient.command('profile.import.url', {
        'metadata': toBackendMetadata(),
        'deviceHeaders': shouldSendHeaders,
      });
    } else {
      final current = await backendClient.profile(id);
      final stored = Map<String, dynamic>.from(current['metadata'] as Map);
      if (stored['url'] != url) {
        await backendClient.command('profile.put', {
          'metadata': {'id': id, 'url': url},
          'expectedRevision': revision,
        });
      }
      await backendClient.command('subscription.refresh', {
        'profileId': id,
        'deviceHeaders': shouldSendHeaders,
      });
    }
    return _readBackend();
  }

  Future<Profile> saveFile(
    Uint8List bytes, {
    int? expectedRevision,
  }) async {
    await backendClient.saveSource(
      toBackendMetadata(),
      bytes,
      expectedRevision: expectedRevision ?? backendClient.profileRevision(id),
    );
    return _readBackend();
  }

  Future<Profile> saveFileWithString(
    String value, {
    int? expectedRevision,
  }) =>
      saveFile(
        Uint8List.fromList(utf8.encode(value)),
        expectedRevision: expectedRevision,
      );
}
