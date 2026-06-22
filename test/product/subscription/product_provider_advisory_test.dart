import 'dart:convert';

import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/subscription/product_subscription.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProductProviderAdvisory', () {
    test('parses display and notice hints into typed advisory data', () {
      final advisory = ProductProviderAdvisory.fromHeaders({
        'announce':
            'base64:${base64.encode(utf8.encode('Maintenance tonight'))}',
        'support-url': 'https://example.com/support',
        'flclashm-servicename': base64.encode(utf8.encode('Service Name')),
        'flclashm-servicelogo':
            base64.encode(utf8.encode('https://example.com/logo.svg')),
        'flclashm-serverinfo': base64.encode(utf8.encode('Auto')),
        'flclashm-background': 'https://example.com/bg.webp',
        'flclashm-globalmode': 'FALSE',
        'flclashm-newboard': 'true',
        'flclashm-denywidgets': 'true',
        'x-hwid-max-devices-reached': 'true',
        'x-hwid-not-supported': 'true',
      });

      expect(advisory.display.announcement, 'Maintenance tonight');
      expect(advisory.display.supportUrl, 'https://example.com/support');
      expect(advisory.display.serviceName, 'Service Name');
      expect(advisory.display.serviceLogoUrl, 'https://example.com/logo.svg');
      expect(advisory.display.serverInfoGroupName, 'Auto');
      expect(
          advisory.display.backgroundUrlOrNull, 'https://example.com/bg.webp');
      expect(advisory.display.globalModeEnabled, isFalse);
      expect(advisory.display.newDashboard, isTrue);
      expect(advisory.display.denyDashboardEditing, isTrue);
      expect(advisory.notices.hwidLimitReached, isTrue);
      expect(advisory.notices.hwidNotSupported, isTrue);
    });

    test('merges refresh headers while clearing volatile notice fields', () {
      final merged = ProductProviderAdvisory.mergeForRefresh(
        previous: {
          'announce': 'old announce',
          'support-url': 'https://old.example.com/support',
          'x-hwid-max-devices-reached': 'true',
          'x-hwid-not-supported': 'true',
          'flclashm-servicename': 'service',
        },
        incoming: {
          'flclashm-background': 'https://example.com/bg.webp',
        },
      );

      expect(merged.containsKey('announce'), isFalse);
      expect(merged.containsKey('support-url'), isFalse);
      expect(merged.containsKey('x-hwid-max-devices-reached'), isFalse);
      expect(merged.containsKey('x-hwid-not-supported'), isFalse);
      expect(merged['flclashm-servicename'], 'service');
      expect(merged['flclashm-background'], 'https://example.com/bg.webp');
    });

    test('builds customization patch for add flow', () {
      final advisory = ProductProviderAdvisory.fromHeaders(const {
        'flclashm-custom': 'add',
        'flclashm-settings':
            'minimize, autorun, shadowstart, autostart, autoupdate',
        'flclashm-hex': '#112233:pureblack',
        'flclashm-widgets': 'serviceInfo, metainfo',
        'flclashm-view':
            'type:tab;sort:name;layout:tight;icon:none;card:oneline',
      });

      final patch = advisory.customization.buildPatch(
        isNewProfile: true,
        appSetting: const AppSettingProps(
          dashboardWidgets: [DashboardWidget.announce],
        ),
        themeProps: defaultThemeProps,
        proxiesStyle: defaultProxiesStyle,
        overrideProviderSettings: false,
      );

      expect(patch.isEmpty, isFalse);
      expect(patch.appSetting?.minimizeOnExit, isTrue);
      expect(patch.appSetting?.autoLaunch, isTrue);
      expect(patch.appSetting?.silentLaunch, isTrue);
      expect(patch.appSetting?.autoRun, isTrue);
      expect(patch.appSetting?.autoCheckUpdate, isTrue);
      expect(
        patch.appSetting?.dashboardWidgets,
        [DashboardWidget.serviceInfo, DashboardWidget.metainfo],
      );
      expect(patch.themeProps?.primaryColor, 0xFF112233);
      expect(patch.themeProps?.pureBlack, isTrue);
      expect(patch.proxiesStyle?.type, ProxiesType.tab);
      expect(patch.proxiesStyle?.sortType, ProxiesSortType.name);
      expect(patch.proxiesStyle?.layout, ProxiesLayout.tight);
      expect(patch.proxiesStyle?.iconStyle, ProxiesIconStyle.none);
      expect(patch.proxiesStyle?.cardType, ProxyCardType.oneline);
    });

    test('keeps provider settings overridden but still applies view hints', () {
      final advisory = ProductProviderAdvisory.fromHeaders(const {
        'flclashm-custom': 'update',
        'flclashm-settings': 'autorun, autostart',
        'flclashm-widgets': 'serviceInfo',
        'flclashm-view': 'sort:delay',
      });

      final patch = advisory.customization.buildPatch(
        isNewProfile: false,
        appSetting: const AppSettingProps(dashboardWidgets: []),
        themeProps: defaultThemeProps,
        proxiesStyle: defaultProxiesStyle,
        overrideProviderSettings: true,
      );

      expect(patch.appSetting?.autoLaunch, isFalse);
      expect(patch.appSetting?.autoRun, isFalse);
      expect(patch.appSetting?.dashboardWidgets, [DashboardWidget.serviceInfo]);
      expect(patch.proxiesStyle?.sortType, ProxiesSortType.delay);
    });

    test('does not apply add-only customization to existing profiles', () {
      final advisory = ProductProviderAdvisory.fromHeaders(const {
        'flclashm-custom': 'add',
        'flclashm-settings': 'autorun',
      });

      final patch = advisory.customization.buildPatch(
        isNewProfile: false,
        appSetting: const AppSettingProps(dashboardWidgets: []),
        themeProps: defaultThemeProps,
        proxiesStyle: defaultProxiesStyle,
        overrideProviderSettings: false,
      );

      expect(patch.isEmpty, isTrue);
    });
  });
}
