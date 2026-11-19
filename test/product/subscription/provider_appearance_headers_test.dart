import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;

void main() {
  test(
    'appearance uses either prefix and prefers the whole FlClashM header',
    () {
      for (final prefix in ['flclashx', 'flclashm']) {
        final headers = ProviderHeaders({
          '$prefix-view':
              'proxies.icon:plain;proxies.card:compact;'
              'app.board:extended;app.navbar:docked;app.tabs:fade;'
              'app.glass:ultra;app.color:123456;app.style:soft;app.black:true',
          '$prefix-background': 'https://example.com/bg.png,40',
          '$prefix-widgets': 'profiles,proxyGroups',
          '$prefix-special': 'noglobal,androidsecure,denywidgets',
        });
        expect(headers.view!.icon, ProxiesIconStyle.plain);
        expect(headers.view!.card, ProxyCardType.compact);
        expect(headers.view!.floatingNavigationBar, false);
        expect(headers.view!.tabAnimation, TabAnimation.fade);
        expect(headers.view!.liquidGlass, LiquidGlassMode.ultra);
        expect(headers.view!.color, 0xff123456);
        expect(headers.view!.pureBlack, true);
        expect(headers.background!.visibility, 40);
        expect(headers.dashboardWidgets, [
          DashboardWidget.profiles,
          DashboardWidget.proxyGroups,
        ]);
        expect(headers.globalModeAllowed, false);
        expect(headers.androidSecure, true);
        expect(headers.widgetEditingDenied, true);
      }
      const headers = ProviderHeaders({
        'flclashx-view': 'app.glass:ultra;app.black:true',
        'flclashm-view': 'app.glass:none',
        'flclashx-special': 'noglobal',
        'flclashm-special': '',
      });
      expect(headers.view!.liquidGlass, LiquidGlassMode.none);
      expect(headers.view!.pureBlack, isNull);
      expect(headers.globalModeAllowed, true);
    },
  );

  test('legacy view keys and standalone restrictions remain readable', () {
    const headers = ProviderHeaders({
      'flclashm-view': 'type:tab;icon:none;card:min',
      'flclashm-globalmode': 'false',
      'flclashm-androidsecure': 'true',
      'flclashm-denywidgets': 'true',
    });
    expect(headers.view!.type, ProxiesType.tab);
    expect(headers.view!.icon, ProxiesIconStyle.hidden);
    expect(headers.view!.card, ProxyCardType.oneline);
    expect(headers.globalModeAllowed, false);
    expect(headers.androidSecure, true);
    expect(headers.widgetEditingDenied, true);
  });

  test('view names the theme and the hidden timeouts in either prefix', () {
    for (final prefix in ['flclashx', 'flclashm']) {
      final headers = ProviderHeaders({
        '$prefix-view': 'app.theme:dark;proxies.hidetimeout:true',
      });
      expect(headers.view!.themeMode, ThemeMode.dark);
      expect(headers.view!.hideTimeout, true);
      expect(headers.view!.touchesTheme, isTrue);
    }
    const fallback = ProviderHeaders({'flclashx-view': 'app.theme:sunset'});
    expect(fallback.view, isNull);
  });

  test('the provider look and one group come from the specials', () {
    const headers = ProviderHeaders({
      'flclashm-special':
          'providermode,nologo,noservice,onegroup,simple,novibrate,'
          'onlytun,hideip,noglobal',
    });
    expect(headers.providerMode, true);
    expect(headers.noLogo, true);
    expect(headers.noService, true);
    expect(headers.oneGroup, true);
    expect(headers.simpleMode, true);
    expect(headers.noVibration, true);
    expect(headers.onlyTun, true);
    expect(headers.hideIp, true);
    expect(headers.globalModeAllowed, false);
    const without = ProviderHeaders({'flclashm-special': ''});
    expect(without.providerMode, false);
    expect(without.oneGroup, false);
  });

  test('app.board no longer picks a dashboard', () {
    const headers = ProviderHeaders({
      'flclashx-view': 'app.board:extended;proxies.card:oneline',
    });
    expect(headers.view!.card, ProxyCardType.oneline);
    const boardOnly = ProviderHeaders({'flclashx-view': 'app.board:extended'});
    expect(boardOnly.view, isNull);
  });

  test('hideip and arranged cards are part of the panel settings', () {
    const hiding = ProviderHeaders({'flclashm-special': 'hideip'});
    expect(hiding.specials, contains('hideip'));
    const without = ProviderHeaders({'flclashm-special': ''});
    expect(without.specials, isNot(contains('hideip')));
    expect(dashboardWidgetsSetting, 'app.dashboardWidgets');
    expect(hideIpSetting, 'app.hideIp');
  });
}
