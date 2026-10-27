import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../common/common.dart';
import '../../database/database.dart';
import '../../enum/enum.dart';
import '../../models/models.dart';
import '../../providers/providers.dart';
import 'backend.dart';
import 'frontend_settings.dart';

class FrontendProjection {
  ProviderContainer? _container;
  StreamSubscription<Map<String, dynamic>>? _events;
  Future<void> _tail = Future.value();
  Timer? _ticker;
  var _hostVisibility = HostVisibilityProjection();
  final _watcher = ProjectionWatcher();
  void attach(ProviderContainer container) {
    _container = container;
    _hostVisibility.dispose();
    _hostVisibility = HostVisibilityProjection(
      onError: (error) => commonPrint.log('Backend visibility: $error'),
    );
    frontendSettingsStore.onSettled = () => unawaited(
      refresh().catchError((Object error) {
        commonPrint.log('Backend read-back: $error');
      }),
    );
    unawaited(_events?.cancel());
    _events = backendClient.changes.listen((_) {
      unawaited(
        refresh().catchError((Object error) {
          commonPrint.log('Backend projection: $error');
        }),
      );
    });
    _ticker?.cancel();
    // Presentation clock only; never schedules subscription/runtime work.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _runtime());
  }

  void _runtime() {
    final c = _container;
    if (c == null) return;
    final runtime = backendClient.snapshot['runtime'] as Map? ?? {};
    final running = runtime['appliedRunning'] == true;
    final timestamp = runtime['startedAt'];
    final started = timestamp is num
        ? DateTime.fromMillisecondsSinceEpoch(timestamp.toInt())
        : null;
    c.read(runTimeProvider.notifier).value = running
        ? (started == null
              ? 0
              : DateTime.now().difference(started).inMilliseconds)
        : null;
    c.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    if (running && c.read(appVisibleProvider)) {
      unawaited(c.read(commonActionProvider.notifier).updateTraffic());
    }
  }

  Future<void> refresh() {
    final run = _tail.then((_) async {
      final c = _container;
      if (c == null) return;
      await database.refreshFromGo(ifChanged: true);
      final config = Config.fromJson(
        frontendSettings(backendClient.sourceSettings),
      );
      frontendSettingsStore.projecting = true;
      try {
        if (!frontendSettingsStore.pending) {
          frontendSettingsStore.project(config);
          writeConfig(c, config);
        }
        _runtime();
      } finally {
        frontendSettingsStore.projecting = false;
      }
      final runtime = backendClient.snapshot['runtime'] as Map? ?? {};
      final instance = runtime['instanceId'] as String?;
      _hostVisibility.synchronize(instance, () async {
        // A replacement service starts with presentation events disabled.
        await c
            .read(coreHandlerProvider)
            .syncHostActive(c.read(appVisibleProvider));
      });
      final changed = _watcher.observe(
        profileId: config.currentProfileId,
        appliedProfileId: backendClient.runtimeView['profileId'] as String?,
        generation: (runtime['appliedGeneration'] as num?)?.toInt(),
      );
      if (changed != ProjectionChange.none || c.read(groupsProvider).isEmpty) {
        if (changed == ProjectionChange.profile) {
          c.read(delayDataSourceProvider.notifier).value = {};
          c.read(requestsProvider.notifier).value = FixedList(
            maxRequestsLength,
          );
          c.read(logsProvider.notifier).value = FixedList(maxLogsLength);
        }
        await c.read(proxiesActionProvider.notifier).updateGroups();
      }
    });
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }
}

final frontendProjection = FrontendProjection();
