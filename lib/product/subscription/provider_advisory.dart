import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show DynamicSchemeVariant;

import '../../enum/enum.dart';
import '../../models/models.dart';

const _announceHeader = 'announce';
const _supportUrlHeader = 'support-url';
const _hwidLimitReachedHeader = 'x-hwid-max-devices-reached';
const _hwidNotSupportedHeader = 'x-hwid-not-supported';
const _serviceNameHeader = 'flclashx-servicename';
const _serviceLogoHeader = 'flclashx-servicelogo';
const _serverInfoHeader = 'flclashx-serverinfo';
const _backgroundUrlHeader = 'flclashx-background';
const _globalModeHeader = 'flclashx-globalmode';
const _newDashboardHeader = 'flclashx-newboard';
const _denyWidgetsHeader = 'flclashx-denywidgets';
const _customBehaviorHeader = 'flclashx-custom';
const _settingsHeader = 'flclashx-settings';
const _themeHeader = 'flclashx-hex';
const _dashboardLayoutHeader = 'flclashx-widgets';
const _proxiesViewHeader = 'flclashx-view';
const _clearedOnMissingRefreshHeaders = {
  _announceHeader,
  _supportUrlHeader,
  _hwidLimitReachedHeader,
  _hwidNotSupportedHeader,
};

enum ProductCustomizationTrigger {
  none,
  add,
  update,
}

@immutable
class ProductProviderAdvisory {
  const ProductProviderAdvisory({
    this.display = const ProductDisplayHints(),
    this.customization = const ProductCustomizationHints(),
    this.notices = const ProductNoticeHints(),
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
          serviceName: _decodeBase64Header(headers[_serviceNameHeader]),
          serviceLogoUrl: _decodeBase64Header(headers[_serviceLogoHeader]),
          serverInfoGroupName: _decodeBase64Header(headers[_serverInfoHeader]),
          backgroundUrl: _trimmedHeader(headers[_backgroundUrlHeader]),
          globalModeEnabled:
              _trimmedHeader(headers[_globalModeHeader]).toLowerCase() !=
                  'false',
          newDashboard: _parseBoolHeader(headers[_newDashboardHeader]),
          denyDashboardEditing: _parseBoolHeader(headers[_denyWidgetsHeader]),
        ),
        customization: ProductCustomizationHints(
          trigger: _parseCustomizationTrigger(headers[_customBehaviorHeader]),
          subscriptionSettings: _parseSubscriptionSettings(headers),
          theme: ProductThemeHint.parse(headers[_themeHeader]),
          dashboardWidgets:
              _parseDashboardWidgets(headers[_dashboardLayoutHeader]),
          proxiesView:
              ProductProxiesViewHint.parse(headers[_proxiesViewHeader]),
        ),
        notices: ProductNoticeHints(
          hwidLimitReached: _parseBoolHeader(headers[_hwidLimitReachedHeader]),
          hwidNotSupported: _parseBoolHeader(headers[_hwidNotSupportedHeader]),
        ),
      );

  final ProductDisplayHints display;
  final ProductCustomizationHints customization;
  final ProductNoticeHints notices;

  static Map<String, String> mergeForRefresh({
    required Map<String, String> previous,
    required Map<String, String> incoming,
  }) {
    final merged = Map<String, String>.from(previous)..addAll(incoming);
    for (final key in _clearedOnMissingRefreshHeaders) {
      if (!incoming.containsKey(key)) {
        merged.remove(key);
      }
    }
    return merged;
  }

  static Set<String>? _parseSubscriptionSettings(Map<String, String> headers) {
    if (!headers.containsKey(_settingsHeader)) {
      return null;
    }
    return headers[_settingsHeader]!
        .split(',')
        .map((value) => value.trim().toLowerCase())
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  static List<DashboardWidget>? _parseDashboardWidgets(String? value) {
    final widgets = DashboardWidgetParser.parseLayout(value);
    return widgets.isEmpty ? null : widgets;
  }

  static ProductCustomizationTrigger _parseCustomizationTrigger(
          String? value) =>
      switch (_trimmedHeader(value).toLowerCase()) {
        'add' => ProductCustomizationTrigger.add,
        'update' => ProductCustomizationTrigger.update,
        _ => ProductCustomizationTrigger.none,
      };

  static bool _parseBoolHeader(String? value) =>
      _trimmedHeader(value).toLowerCase() == 'true';

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
class ProductCustomizationHints {
  const ProductCustomizationHints({
    this.trigger = ProductCustomizationTrigger.none,
    this.subscriptionSettings,
    this.theme,
    this.dashboardWidgets,
    this.proxiesView,
  });

  final ProductCustomizationTrigger trigger;
  final Set<String>? subscriptionSettings;
  final ProductThemeHint? theme;
  final List<DashboardWidget>? dashboardWidgets;
  final ProductProxiesViewHint? proxiesView;

  bool appliesToProfile({required bool isNewProfile}) => switch (trigger) {
        ProductCustomizationTrigger.add => isNewProfile,
        ProductCustomizationTrigger.update => true,
        ProductCustomizationTrigger.none => false,
      };

  ProductCustomizationPatch buildPatch({
    required bool isNewProfile,
    required AppSettingProps appSetting,
    required ThemeProps themeProps,
    required ProxiesStyle proxiesStyle,
    required bool overrideProviderSettings,
  }) {
    if (!appliesToProfile(isNewProfile: isNewProfile)) {
      return const ProductCustomizationPatch();
    }

    var nextAppSetting = appSetting;
    var nextThemeProps = themeProps;
    var nextProxiesStyle = proxiesStyle;
    var appSettingChanged = false;
    var themeChanged = false;
    var proxiesStyleChanged = false;

    if (subscriptionSettings != null && !overrideProviderSettings) {
      final updatedAppSetting = nextAppSetting.copyWith(
        minimizeOnExit: subscriptionSettings!.contains('minimize'),
        autoLaunch: subscriptionSettings!.contains('autorun'),
        silentLaunch: subscriptionSettings!.contains('shadowstart'),
        autoRun: subscriptionSettings!.contains('autostart'),
        autoCheckUpdate: subscriptionSettings!.contains('autoupdate'),
      );
      if (updatedAppSetting != nextAppSetting) {
        nextAppSetting = updatedAppSetting;
        appSettingChanged = true;
      }
    }

    final dashboardWidgets = this.dashboardWidgets;
    if (dashboardWidgets != null && dashboardWidgets.isNotEmpty) {
      final updatedAppSetting = nextAppSetting.copyWith(
        dashboardWidgets: dashboardWidgets,
      );
      if (updatedAppSetting != nextAppSetting) {
        nextAppSetting = updatedAppSetting;
        appSettingChanged = true;
      }
    }

    if (theme != null) {
      final updatedTheme = theme!.applyTo(nextThemeProps);
      if (updatedTheme != nextThemeProps) {
        nextThemeProps = updatedTheme;
        themeChanged = true;
      }
    }

    if (proxiesView != null) {
      final updatedProxiesStyle = proxiesView!.applyTo(nextProxiesStyle);
      if (updatedProxiesStyle != nextProxiesStyle) {
        nextProxiesStyle = updatedProxiesStyle;
        proxiesStyleChanged = true;
      }
    }

    return ProductCustomizationPatch(
      appSetting: appSettingChanged ? nextAppSetting : null,
      themeProps: themeChanged ? nextThemeProps : null,
      proxiesStyle: proxiesStyleChanged ? nextProxiesStyle : null,
    );
  }
}

@immutable
class ProductCustomizationPatch {
  const ProductCustomizationPatch({
    this.appSetting,
    this.themeProps,
    this.proxiesStyle,
  });

  final AppSettingProps? appSetting;
  final ThemeProps? themeProps;
  final ProxiesStyle? proxiesStyle;

  bool get isEmpty =>
      appSetting == null && themeProps == null && proxiesStyle == null;
}

@immutable
class ProductThemeHint {
  const ProductThemeHint({
    required this.primaryColor,
    this.variant,
    required this.pureBlack,
  });

  static ProductThemeHint? parse(String? value) {
    final normalizedValue = value?.trim() ?? '';
    if (normalizedValue.isEmpty) {
      return null;
    }

    final parts = normalizedValue.split(':');
    final hexString = parts.first.trim().replaceAll('#', '');
    if (hexString.length != 6 && hexString.length != 8) {
      return null;
    }

    final colorValue = int.tryParse(
      hexString.length == 6 ? 'FF$hexString' : hexString,
      radix: 16,
    );
    if (colorValue == null) {
      return null;
    }

    var variantName = parts.length > 1 ? parts[1].trim() : '';
    if (variantName.toLowerCase() == 'pureblack') {
      variantName = '';
    }

    DynamicSchemeVariant? variant;
    if (variantName.isNotEmpty) {
      for (final item in DynamicSchemeVariant.values) {
        if (item.name.toLowerCase() == variantName.toLowerCase()) {
          variant = item;
          break;
        }
      }
    }

    final pureBlack = parts
        .skip(1)
        .map((part) => part.trim().toLowerCase())
        .contains('pureblack');

    return ProductThemeHint(
      primaryColor: colorValue,
      variant: variant,
      pureBlack: pureBlack,
    );
  }

  final int primaryColor;
  final DynamicSchemeVariant? variant;
  final bool pureBlack;

  ThemeProps applyTo(ThemeProps current) {
    final primaryColors = [...current.primaryColors];
    if (!primaryColors.contains(primaryColor)) {
      primaryColors.add(primaryColor);
    }
    return current.copyWith(
      primaryColor: primaryColor,
      primaryColors: primaryColors,
      schemeVariant: variant ?? current.schemeVariant,
      pureBlack: pureBlack,
    );
  }
}

@immutable
class ProductProxiesViewHint {
  const ProductProxiesViewHint({
    this.type,
    this.sortType,
    this.layout,
    this.iconStyle,
    this.cardType,
  });

  static ProductProxiesViewHint? parse(String? value) {
    final normalizedValue = value?.trim() ?? '';
    if (normalizedValue.isEmpty) {
      return null;
    }

    ProxiesType? type;
    ProxiesSortType? sortType;
    ProxiesLayout? layout;
    ProxiesIconStyle? iconStyle;
    ProxyCardType? cardType;

    final settings = normalizedValue.split(';');
    for (final setting in settings) {
      final parts = setting.split(':');
      if (parts.length != 2) {
        continue;
      }
      final key = parts[0].trim().toLowerCase();
      final option = parts[1].trim().toLowerCase();
      switch (key) {
        case 'type':
          type = switch (option) {
            'list' => ProxiesType.list,
            'tab' => ProxiesType.tab,
            _ => type,
          };
          break;
        case 'sort':
          sortType = switch (option) {
            'none' => ProxiesSortType.none,
            'delay' => ProxiesSortType.delay,
            'name' => ProxiesSortType.name,
            _ => sortType,
          };
          break;
        case 'layout':
          layout = switch (option) {
            'loose' => ProxiesLayout.loose,
            'standard' => ProxiesLayout.standard,
            'tight' => ProxiesLayout.tight,
            _ => layout,
          };
          break;
        case 'icon':
          iconStyle = switch (option) {
            'icon' || 'standard' => ProxiesIconStyle.icon,
            'none' => ProxiesIconStyle.none,
            _ => iconStyle,
          };
          break;
        case 'card':
          cardType = switch (option) {
            'expand' => ProxyCardType.expand,
            'shrink' => ProxyCardType.shrink,
            'min' => ProxyCardType.min,
            'oneline' => ProxyCardType.oneline,
            _ => cardType,
          };
          break;
      }
    }

    if (type == null &&
        sortType == null &&
        layout == null &&
        iconStyle == null &&
        cardType == null) {
      return null;
    }

    return ProductProxiesViewHint(
      type: type,
      sortType: sortType,
      layout: layout,
      iconStyle: iconStyle,
      cardType: cardType,
    );
  }

  final ProxiesType? type;
  final ProxiesSortType? sortType;
  final ProxiesLayout? layout;
  final ProxiesIconStyle? iconStyle;
  final ProxyCardType? cardType;

  ProxiesStyle applyTo(ProxiesStyle current) => current.copyWith(
        type: type ?? current.type,
        sortType: sortType ?? current.sortType,
        layout: layout ?? current.layout,
        iconStyle: iconStyle ?? current.iconStyle,
        cardType: cardType ?? current.cardType,
      );
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
