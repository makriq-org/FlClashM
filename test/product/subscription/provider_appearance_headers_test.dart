import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

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
        expect(headers.view!.board, ThemeStyle.enhanced);
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
    expect(headers.view!.card, ProxyCardType.compact);
    expect(headers.globalModeAllowed, false);
    expect(headers.androidSecure, true);
    expect(headers.widgetEditingDenied, true);
  });
}
