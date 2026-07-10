import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/services/tunnel_access_inspector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const inspector = TunnelAccessInspector();
  const selfPackages = ['com.example.self', 'com.example.self.dev'];

  group('TunnelAccessInspector.inspect', () {
    test('manual exclude list keeps its apps and adds the self bypass', () {
      final report = inspector.inspect(
        manualAccessControl: const AccessControl(
          enable: true,
          mode: AccessControlMode.rejectSelected,
          rejectList: ['com.example.blocked'],
        ),
        selfPackageNames: selfPackages,
      );

      expect(report.source, TunnelAccessSource.manual);
      expect(report.enabled, isTrue);
      expect(report.mode, AccessControlMode.rejectSelected);
      expect(report.isWhitelist, isFalse);
      expect(report.configuredPackages, ['com.example.blocked']);
      expect(
        report.effectivePackages,
        containsAll(<String>['com.example.blocked', ...selfPackages]),
      );
      expect(report.selfBypassPackages, containsAll(selfPackages));
    });

    test('profile access control overrides manual settings', () {
      final report = inspector.inspect(
        manualAccessControl: const AccessControl(
          enable: true,
          mode: AccessControlMode.rejectSelected,
          rejectList: ['com.example.manual'],
        ),
        profileAccessControl: const AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: ['com.example.profile'],
        ),
        selfPackageNames: selfPackages,
      );

      expect(report.source, TunnelAccessSource.profile);
      expect(report.mode, AccessControlMode.acceptSelected);
      expect(report.isWhitelist, isTrue);
      expect(report.configuredPackages, ['com.example.profile']);
      // The self package is not part of an accept list, so it stays out of the
      // whitelist (which already keeps it bypassing the tunnel).
      expect(report.effectivePackages, ['com.example.profile']);
      expect(report.selfBypassPackages, isEmpty);
    });

    test('include list with foreign apps stays a whitelist and drops self', () {
      final report = inspector.inspect(
        manualAccessControl: AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: ['com.example.kept', selfPackages.first],
        ),
        selfPackageNames: selfPackages,
      );

      expect(report.mode, AccessControlMode.acceptSelected);
      expect(report.effectivePackages, ['com.example.kept']);
      expect(report.effectivePackages, isNot(contains(selfPackages.first)));
      expect(report.selfBypassPackages, isEmpty);
    });

    test('include list of only the self package flips to a self bypass', () {
      final report = inspector.inspect(
        manualAccessControl: AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: [selfPackages.first],
        ),
        selfPackageNames: selfPackages,
      );

      expect(report.mode, AccessControlMode.rejectSelected);
      expect(report.enabled, isTrue);
      expect(report.effectivePackages, selfPackages);
      expect(report.selfBypassPackages, selfPackages);
    });

    test('disabled manual access control still bypasses the self package', () {
      final report = inspector.inspect(
        manualAccessControl: const AccessControl(enable: false),
        selfPackageNames: selfPackages,
      );

      expect(report.source, TunnelAccessSource.manual);
      expect(report.enabled, isTrue);
      expect(report.mode, AccessControlMode.rejectSelected);
      expect(report.configuredPackages, isEmpty);
      expect(report.effectivePackages, selfPackages);
      expect(report.selfBypassPackages, selfPackages);
    });

    test('effective and configured lists are unmodifiable', () {
      final report = inspector.inspect(
        manualAccessControl: const AccessControl(
          enable: true,
          mode: AccessControlMode.rejectSelected,
          rejectList: ['com.example.blocked'],
        ),
        selfPackageNames: selfPackages,
      );

      expect(
        () => report.effectivePackages.add('com.example.mutate'),
        throwsUnsupportedError,
      );
      expect(
        () => report.configuredPackages.add('com.example.mutate'),
        throwsUnsupportedError,
      );
    });
  });

  group('TunnelAccessReport.hasObservedDrift', () {
    AndroidVpnOptions optionsWith({
      required AccessControl accessControl,
      List<String> includePackage = const [],
      List<String> excludePackage = const [],
    }) =>
        AndroidVpnOptions(
          enable: true,
          port: 7890,
          accessControl: accessControl,
          allowBypass: true,
          systemProxy: false,
          bypassDomain: const [],
          ipv4Address: '172.19.0.1/30',
          ipv6Address: '',
          dnsServerAddress: '172.19.0.2',
          includePackage: includePackage,
          excludePackage: excludePackage,
        );

    test('no observation means no drift', () {
      final report = inspector.inspect(
        manualAccessControl: const AccessControl(
          enable: true,
          rejectList: ['com.example.blocked'],
        ),
        selfPackageNames: selfPackages,
      );

      expect(report.observation, isNull);
      expect(report.hasObservedDrift, isFalse);
    });

    test('matching running core reports no drift', () {
      final report = inspector.inspect(
        manualAccessControl: const AccessControl(
          enable: true,
          mode: AccessControlMode.rejectSelected,
          rejectList: ['com.example.blocked'],
        ),
        observedOptions: optionsWith(
          accessControl: const AccessControl(
            enable: true,
            mode: AccessControlMode.rejectSelected,
            rejectList: ['com.example.blocked', ...selfPackages],
          ),
          excludePackage: const ['com.example.blocked'],
        ),
        selfPackageNames: selfPackages,
      );

      expect(report.observation, isNotNull);
      expect(report.hasObservedDrift, isFalse);
    });

    test('diverging running core reports drift', () {
      final report = inspector.inspect(
        manualAccessControl: const AccessControl(
          enable: true,
          mode: AccessControlMode.rejectSelected,
          rejectList: ['com.example.blocked'],
        ),
        observedOptions: optionsWith(
          accessControl: const AccessControl(
            enable: true,
            mode: AccessControlMode.rejectSelected,
            rejectList: ['com.example.stale'],
          ),
        ),
        selfPackageNames: selfPackages,
      );

      expect(report.hasObservedDrift, isTrue);
    });

    test('a different running mode reports drift', () {
      final report = inspector.inspect(
        manualAccessControl: const AccessControl(
          enable: true,
          mode: AccessControlMode.rejectSelected,
          rejectList: ['com.example.blocked'],
        ),
        observedOptions: optionsWith(
          accessControl: const AccessControl(
            enable: true,
            mode: AccessControlMode.acceptSelected,
            acceptList: ['com.example.blocked'],
          ),
        ),
        selfPackageNames: selfPackages,
      );

      expect(report.hasObservedDrift, isTrue);
    });

    test('observation exposes the config-declared split tunneling lists', () {
      final report = inspector.inspect(
        manualAccessControl: const AccessControl(enable: false),
        observedOptions: optionsWith(
          accessControl: const AccessControl(
            enable: true,
            mode: AccessControlMode.rejectSelected,
            rejectList: selfPackages,
          ),
          excludePackage: const ['com.example.declared'],
        ),
        selfPackageNames: selfPackages,
      );

      expect(report.observation!.excludePackages, ['com.example.declared']);
      expect(report.observation!.appliedPackages, selfPackages);
      expect(report.hasObservedDrift, isFalse);
    });
  });
}
