import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/views/dashboard/widget_registry.dart';
import 'package:flclashx/views/dashboard/widgets/card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  testWidgets('header fits the title beside an empty or short badge', (
    tester,
  ) async {
    const title = 'Proxy groups';
    for (final width in [0.0, 20.0]) {
      await tester.pumpWidget(
        TestApp(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 220,
              child: DashboardCardHeader(
                title: title,
                leading: [SizedBox(width: width, height: 16)],
              ),
            ),
          ),
        ),
      );

      final paragraph = tester.renderObject<RenderParagraph>(find.text(title));
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: 'Badge width: $width',
      );
    }
  });

  test('the standard page keeps the status card on top', () {
    final cards = withFixedCards([
      DashboardWidget.profiles,
      DashboardWidget.memoryInfo,
    ], announcement: false);
    expect(cards.first, DashboardWidget.currentOutbound);
  });

  test(
    'providermode lets the status card go and the server take its place',
    () {
      final cards = withFixedCards(
        [DashboardWidget.profiles, DashboardWidget.memoryInfo],
        announcement: false,
        providerMode: true,
      );
      expect(cards, isNot(contains(DashboardWidget.currentOutbound)));
      expect(
        DashboardWidget.currentOutbound.removable(providerMode: true),
        isTrue,
      );
      expect(
        DashboardWidget.currentOutbound.removable(providerMode: false),
        isFalse,
      );
      expect(DashboardWidget.profiles.removable(providerMode: false), isTrue);
      expect(
        DashboardWidget.announcement.removable(providerMode: true),
        isFalse,
      );
    },
  );

  test('an announcement the list never placed goes on top', () {
    final cards = withFixedCards([
      DashboardWidget.profiles,
    ], announcement: true);
    expect(cards.first, DashboardWidget.announcement);
    expect(cards, contains(DashboardWidget.currentOutbound));
  });
}
