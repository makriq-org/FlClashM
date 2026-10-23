import 'dart:convert';

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
        'flclashm-servicelogo': base64.encode(
          utf8.encode('https://example.com/logo.svg'),
        ),
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
        advisory.display.backgroundUrlOrNull,
        'https://example.com/bg.webp',
      );
      expect(advisory.display.globalModeEnabled, isFalse);
      expect(advisory.display.newDashboard, isTrue);
      expect(advisory.display.denyDashboardEditing, isTrue);
      expect(advisory.notices.hwidLimitReached, isTrue);
      expect(advisory.notices.hwidNotSupported, isTrue);
    });

    test('accepts upstream headers and prefers the FlClashM prefix', () {
      final advisory = ProductProviderAdvisory.fromHeaders({
        'flclashx-servicename': base64.encode(utf8.encode('Upstream')),
        'flclashm-servicename': base64.encode(utf8.encode('FlClashM')),
        'flclashx-buyplan': 'https://upstream.example/renew',
        'flclashm-buyplan': 'https://flclashm.example/renew',
        'flclashx-buytraffic': 'https://example.com/traffic',
        'flclashx-androidsecure': 'true',
      });

      expect(advisory.display.serviceName, 'FlClashM');
      expect(advisory.display.buyPlanUrl, 'https://flclashm.example/renew');
      expect(advisory.display.buyTrafficUrl, 'https://example.com/traffic');
      expect(advisory.behavior.androidSecure, isTrue);
    });
  });
}
