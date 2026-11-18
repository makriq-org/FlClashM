import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/views/dashboard/widget_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the standard page keeps the status card on top', () {
    final cards = withFixedCards([
      DashboardWidget.profiles,
      DashboardWidget.memoryInfo,
    ], announcement: false);
    expect(cards.first, DashboardWidget.currentOutbound);
  });

  test('providermode lets the status card go and the server take its place', () {
    final cards = withFixedCards([
      DashboardWidget.profiles,
      DashboardWidget.memoryInfo,
    ], announcement: false, providerMode: true);
    expect(cards, isNot(contains(DashboardWidget.currentOutbound)));
    expect(
      DashboardWidget.currentOutbound.removable(providerMode: true),
      isTrue,
    );
    expect(
      DashboardWidget.currentOutbound.removable(providerMode: false),
      isFalse,
    );
    expect(
      DashboardWidget.profiles.removable(providerMode: false),
      isTrue,
    );
    expect(
      DashboardWidget.announcement.removable(providerMode: true),
      isFalse,
    );
  });

  test('an announcement the list never placed goes on top', () {
    final cards = withFixedCards([
      DashboardWidget.profiles,
    ], announcement: true);
    expect(cards.first, DashboardWidget.announcement);
    expect(cards, contains(DashboardWidget.currentOutbound));
  });
}
