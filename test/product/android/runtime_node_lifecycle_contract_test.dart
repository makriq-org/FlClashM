import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String manager;
  late String connectivityChecker;
  late String remoteService;
  late String vpnService;

  setUpAll(() async {
    manager = await File(
      'android/service/src/main/kotlin/com/follow/clashx/service/'
      'RuntimeNodeProcessManager.kt',
    ).readAsString();
    connectivityChecker = await File(
      'android/service/src/main/kotlin/com/follow/clashx/service/'
      'RuntimeNodeConnectivityChecker.kt',
    ).readAsString();
    remoteService = await File(
      'android/service/src/main/kotlin/com/follow/clashx/service/'
      'RemoteService.kt',
    ).readAsString();
    vpnService = await File(
      'android/service/src/main/kotlin/com/follow/clashx/service/'
      'FlVpnService.kt',
    ).readAsString();
  });

  test('Android starts and fully stops independent nodes concurrently', () {
    expect(
      manager,
      contains('target.values.map { spec ->\n                async'),
    );
    expect(
      manager,
      contains('specs.map { spec -> async { stop(spec.nodeId) } }.awaitAll()'),
    );
    expect(manager, contains('SOFT_STOP_MILLIS = 500L'));
    expect(manager, contains('FORCE_STOP_MILLIS = 500L'));
  });

  test('readiness requires a live process, listener, and required check', () {
    final listener = manager.indexOf('waitForListener(spec, deadline)');
    final alive = manager.indexOf('exited after opening its local listener');
    final required =
        manager.indexOf('check.required && check.urls.isNotEmpty()');

    expect(listener, greaterThan(0));
    expect(alive, greaterThan(listener));
    expect(required, greaterThan(alive));
  });

  test('connectivity probes close sockets on every exit path', () {
    final probeStart = connectivityChecker.indexOf('private suspend fun probe');
    final probeEnd = connectivityChecker.indexOf(
      'private fun socksConnect',
      probeStart,
    );
    final probe = connectivityChecker.substring(probeStart, probeEnd);

    expect(probe, contains('finally'));
    expect(probe, contains('socket.close()'));
    expect(probe, contains('rawSocket.close()'));
  });

  test('strategy probes are service-owned, serialized and always stopped', () {
    final probe = manager.indexOf('suspend fun probeNode');
    final lock = manager.indexOf('planLock.withLock', probe);
    final prepare = manager.indexOf('prepareNode(spec).ready', probe);
    final cleanup = manager.indexOf('stop(spec.nodeId)', prepare);

    expect(probe, greaterThan(0));
    expect(lock, greaterThan(probe));
    expect(prepare, greaterThan(lock));
    expect(cleanup, greaterThan(prepare));
    expect(remoteService, contains('RuntimeNodeProcessManager.probeNode'));
  });

  test('batch strategy probes release the plan lock before running', () {
    final probe = manager.indexOf('suspend fun probeNodes');
    final end = manager.indexOf('fun readPlanState', probe);
    final batchProbe = manager.substring(probe, end);

    expect(
      batchProbe,
      isNot(contains('requestJson: String): Int = planLock.withLock')),
    );
    expect(batchProbe, contains('val specs = planLock.withLock'));
    expect(
      batchProbe.indexOf('selectRuntimeNodeProbeIndex'),
      greaterThan(batchProbe.lastIndexOf('val specs = planLock.withLock')),
    );
  });

  test('optional checks are one non-blocking job per plan generation', () {
    expect(manager, contains('optionalCheckJob?.cancelAndJoin()'));
    expect(manager, contains('optionalCheckJob = GlobalState.scope.launch'));
    expect(
      manager.indexOf('launchOptionalChecks(currentGeneration'),
      greaterThan(manager.indexOf('activePlan = LinkedHashMap(target)')),
    );
    expect(
      manager.indexOf(
          'if (target == previousPlan && reusable.size == target.size)'),
      lessThan(manager.indexOf('optionalCheckJob?.cancelAndJoin()')),
    );
  });

  test('normal VPN stop retains nodes until the last UI client detaches', () {
    expect(vpnService, contains('RuntimeNodeProcessManager.stopIfIdle'));
    expect(remoteService, contains('RuntimeNodeClientRegistry.detach()'));
    expect(
      remoteService,
      contains('stopIfIdle(vpnActive = State.runTime != 0L)'),
    );
  });

  test('proc traversal remains an emergency-only cleanup', () {
    final emergencyGuard = manager.indexOf('if (needsEmergencySweep)');
    final procTraversal = manager.indexOf('File("/proc").listFiles()');
    expect(emergencyGuard, greaterThan(0));
    expect(procTraversal, greaterThan(emergencyGuard));
    expect(
        manager.substring(0, emergencyGuard), isNot(contains('File("/proc")')));
  });
}
