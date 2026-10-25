import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/models.dart';

const _announceHeader = 'announce';
const _supportUrlHeader = 'support-url';
const _hwidLimitReachedHeader = 'x-hwid-max-devices-reached';
const _hwidNotSupportedHeader = 'x-hwid-not-supported';

@immutable
class ProductProviderAdvisory {
  const ProductProviderAdvisory({
    this.display = const ProductDisplayHints(),
    this.customization = const ProductCustomizationHints(),
    this.notices = const ProductNoticeHints(),
    this.behavior = const ProductBehaviorHints(),
  });

  factory ProductProviderAdvisory.fromProfile(Profile? profile) =>
      ProductProviderAdvisory.fromHeaders(
        profile?.providerHeaders ?? const <String, String>{},
      );

  factory ProductProviderAdvisory.fromHeaders(Map<String, String> headers) =>
      ProductProviderAdvisory(
        display: ProductDisplayHints(
          announcement: _decodeAnnouncement(headers[_announceHeader]),
          supportUrl: _trimmedHeader(headers[_supportUrlHeader]),
          serviceName: _decodeBase64Header(
            _providerHeader(headers, 'servicename'),
          ),
          serviceLogoUrl: _decodeBase64Header(
            _providerHeader(headers, 'servicelogo'),
          ),
          serverInfoGroupName: _decodeBase64Header(
            _providerHeader(headers, 'serverinfo'),
          ),
          backgroundUrl: _trimmedHeader(_providerHeader(headers, 'background')),
          buyPlanUrl: _trimmedHeader(_providerHeader(headers, 'buyplan')),
          buyTrafficUrl: _trimmedHeader(_providerHeader(headers, 'buytraffic')),
          globalModeEnabled:
              _trimmedHeader(_providerHeader(headers, 'globalmode'))
                  .toLowerCase() !=
              'false',
          newDashboard: _parseBoolHeader(_providerHeader(headers, 'newboard')),
          denyDashboardEditing: _parseBoolHeader(
            _providerHeader(headers, 'denywidgets'),
          ),
        ),
        customization: ProductCustomizationHints(
          subscriptionSettings: _parseSubscriptionSettings(headers),
        ),
        notices: ProductNoticeHints(
          hwidLimitReached: _parseBoolHeader(headers[_hwidLimitReachedHeader]),
          hwidNotSupported: _parseBoolHeader(headers[_hwidNotSupportedHeader]),
        ),
        behavior: ProductBehaviorHints(
          androidSecure: _parseBoolHeader(
            _providerHeader(headers, 'androidsecure'),
          ),
        ),
      );

  final ProductDisplayHints display;
  final ProductCustomizationHints customization;
  final ProductNoticeHints notices;
  final ProductBehaviorHints behavior;

  static Set<String>? _parseSubscriptionSettings(Map<String, String> headers) {
    final value = _providerHeader(headers, 'settings');
    if (value == null) {
      return null;
    }
    return value
        .split(',')
        .map((value) => value.trim().toLowerCase())
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  static bool _parseBoolHeader(String? value) =>
      _trimmedHeader(value).toLowerCase() == 'true';

  static String? _providerHeader(Map<String, String> headers, String suffix) =>
      resolveFlClashProviderHeader(headers, suffix);

  static String _trimmedHeader(String? value) => value?.trim() ?? '';

  static String _decodeBase64Header(String? value) {
    final normalizedValue = _trimmedHeader(value);
    if (normalizedValue.isEmpty) {
      return '';
    }
    try {
      return utf8
          .decode(base64.decode(base64.normalize(normalizedValue)))
          .trim();
    } catch (_) {
      return normalizedValue;
    }
  }

  static String _decodeAnnouncement(String? value) {
    final normalizedValue = _trimmedHeader(value);
    if (normalizedValue.isEmpty) {
      return '';
    }
    final payload = normalizedValue.startsWith('base64:')
        ? normalizedValue.substring(7)
        : normalizedValue;
    final decoded = _decodeBase64Header(payload);
    return decoded.isEmpty ? normalizedValue : decoded;
  }
}

@immutable
class ProductDisplayHints {
  const ProductDisplayHints({
    this.announcement = '',
    this.supportUrl = '',
    this.serviceName = '',
    this.serviceLogoUrl = '',
    this.serverInfoGroupName = '',
    this.backgroundUrl = '',
    this.buyPlanUrl = '',
    this.buyTrafficUrl = '',
    this.globalModeEnabled = true,
    this.newDashboard = false,
    this.denyDashboardEditing = false,
  });

  final String announcement;
  final String supportUrl;
  final String serviceName;
  final String serviceLogoUrl;
  final String serverInfoGroupName;
  final String backgroundUrl;
  final String buyPlanUrl;
  final String buyTrafficUrl;
  final bool globalModeEnabled;
  final bool newDashboard;
  final bool denyDashboardEditing;

  bool get hasAnnouncement => announcement.isNotEmpty;

  bool get hasServiceInfo => serviceName.isNotEmpty;

  bool get hasServerInfo => serverInfoGroupName.isNotEmpty;

  bool get hasSupportUrl => supportUrl.isNotEmpty;

  String? get supportUrlOrNull => hasSupportUrl ? supportUrl : null;

  String? get backgroundUrlOrNull =>
      backgroundUrl.isNotEmpty ? backgroundUrl : null;
}

@immutable
class ProductBehaviorHints {
  const ProductBehaviorHints({this.androidSecure = false});

  final bool androidSecure;
}

/// Read-only hint used to render provider-managed settings controls.
@immutable
class ProductCustomizationHints {
  const ProductCustomizationHints({this.subscriptionSettings});
  final Set<String>? subscriptionSettings;
}

@immutable
class ProductNoticeHints {
  const ProductNoticeHints({
    this.hwidLimitReached = false,
    this.hwidNotSupported = false,
  });

  final bool hwidLimitReached;
  final bool hwidNotSupported;
}
