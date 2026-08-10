import 'package:flclashx/application.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/manager/hotkey_manager.dart';
import 'package:flclashx/manager/manager.dart';
import 'package:flclashx/product/platform/platform_profile.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('desktop uses the existing desktop shell managers', (
    tester,
  ) async {
    final profile = ProductPlatformProfile.fromOperatingSystem('linux');
    const leaf = SizedBox();

    final shell = buildProductPlatformState(profile: profile, child: leaf);
    expect(shell, isA<WindowManager>());
    final tray = (shell as WindowManager).child;
    expect(tray, isA<TrayManager>());
    final hotKey = (tray as TrayManager).child;
    expect(hotKey, isA<HotKeyManager>());
    final proxy = (hotKey as HotKeyManager).child;
    expect(proxy, isA<ProxyManager>());
    expect((proxy as ProxyManager).child, same(leaf));

    final app = buildProductPlatformApp(profile: profile, child: leaf);
    expect(app, isA<WindowHeaderContainer>());
    expect(profile.resolveNavigationMode(320), NavigationItemMode.desktop);
  });

  testWidgets('Android keeps the mobile shell and navigation', (tester) async {
    final profile = ProductPlatformProfile.fromOperatingSystem('android');
    const leaf = SizedBox();

    final shell = buildProductPlatformState(profile: profile, child: leaf);
    expect(shell, isA<AndroidManager>());
    expect((shell as AndroidManager).child, same(leaf));

    final app = buildProductPlatformApp(profile: profile, child: leaf);
    expect(app, isA<VpnManager>());
    expect(profile.resolveNavigationMode(1200), NavigationItemMode.mobile);
  });
}
