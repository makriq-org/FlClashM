import 'package:flclashx/common/service_probe.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/ip_quality.dart';
import 'package:flclashx/providers/outbound_ip.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/providers/routed_probe.dart';
import 'package:flclashx/views/dashboard/widgets/current_outbound.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_app.dart';

const _ip = '203.0.113.5';
const _profile = Profile(id: 'test', autoUpdateDuration: Duration.zero);

class _CachedExitProbe extends OutboundIpProbe {
  @override
  RoutedProbeState<String, IpInfo> build() => const RoutedProbeState({
    routedOutbound: ProbeEntry(
      phase: ProbePhase.fresh,
      value: IpInfo(ip: _ip, countryCode: ''),
    ),
  });

  @override
  void watch(String target) {}

  @override
  void unwatch(String target) {}
}

void main() {
  testWidgets('stopping the VPN hides the cached exit address', (tester) async {
    final container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWithBuild((_, _) => [_profile]),
        currentProfileIdProvider.overrideWithBuild((_, _) => _profile.id),
        currentGroupsStateProvider.overrideWith(
          (_) => const GroupsState(value: []),
        ),
        visibleGroupsStateProvider.overrideWith(
          (_) => const GroupsState(value: []),
        ),
        appSettingProvider.overrideWithBuild((_, _) => const AppSettingProps()),
        outboundIpProbeProvider.overrideWith(_CachedExitProbe.new),
        ipQualityProvider(_ip).overrideWith(
          (_) async => const IpQuality(
            ip: _ip,
            source: IpQualitySource.ipInfo,
            type: IpType.hosting,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final runTime = container.read(runTimeProvider.notifier);
    runTime.value = DateTime.now().millisecondsSinceEpoch;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(
          locale: Locale('en'),
          child: Scaffold(body: CurrentOutboundCard()),
        ),
      ),
    );

    expect(find.text(_ip), findsOneWidget);

    runTime.value = null;
    await tester.pumpAndSettle();

    expect(find.text(_ip), findsNothing);
    expect(find.text('Not running'), findsOneWidget);
  });
}
