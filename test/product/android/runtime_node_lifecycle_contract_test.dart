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

  test('strategy probes resolve the target off the fake-ip system resolver', () {
    final probeStart = connectivityChecker.indexOf('private suspend fun probe');
    final probeEnd = connectivityChecker.indexOf(
      'private fun socksConnect',
      probeStart,
    );
    final probe = connectivityChecker.substring(probeStart, probeEnd);

    // The probe never resolves the test host through the system resolver (which
    // answers with mihomo's fake-ip); it delegates to resolveSocksTarget.
    expect(
      probe,
      contains('resolveSocksTarget(uri.host, resolver, timeoutMillis)'),
    );
    expect(probe, contains('socksConnect(rawSocket, socksTarget, targetPort)'));
    expect(probe, isNot(contains('InetAddress.getAllByName(uri.host)')));
    // Default path resolves via DoH; the `system` escape hatch still hands byedpi
    // the domain over SOCKS (ATYP 0x03) for underlying-network resolution.
    expect(connectivityChecker, contains('application/dns-message'));
    expect(connectivityChecker, contains('0x03, host.size.toByte()'));
  });

  test('an unreachable DoH resolver degrades instead of failing every probe',
      () {
    final start = connectivityChecker.indexOf('private fun resolveSocksTarget');
    final end = connectivityChecker.indexOf('private fun dohResolve', start);
    final resolveTarget = connectivityChecker.substring(start, end);

    // DoH is itself blocked on many of the networks this feature targets. An
    // empty answer must fall back to byedpi-side resolution, otherwise every
    // strategy fails and auto-selection can never settle.
    expect(resolveTarget, contains('if (answers.isEmpty()) {'));
    expect(resolveTarget, contains('return host'));
    // A resolver that answers only with loopback/LAN addresses is still refused.
    expect(resolveTarget, contains('firstOrNull(::isPublicAddress)'));

    // The resolver is dialled directly, so it passes the same safety gate as the
    // check URLs rather than being trusted from the plan JSON.
    expect(
      connectivityChecker,
      contains('Unsafe connectivity-check resolver'),
    );
    // DoH gets its own sub-budget and its answers are reused across the sweep.
    expect(connectivityChecker, contains('DOH_CACHE_TTL_MILLIS'));
    expect(
      connectivityChecker,
      contains('(timeoutMillis / 2).coerceIn(1_000L, 3_000L)'),
    );
    // A hostile resolver cannot stream the probe out of memory.
    expect(connectivityChecker, contains('readAtMost(MAX_DOH_RESPONSE_BYTES)'));
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

  test('plan transitions cancel and join registered batch probes', () {
    final probe = manager.indexOf('suspend fun probeNodes');
    final probeEnd = manager.indexOf('fun readPlanState', probe);
    final batchProbe = manager.substring(probe, probeEnd);
    final transition = manager.indexOf(
      'private suspend fun <T> withBatchProbesStopped',
    );
    final transitionEnd = manager.indexOf('suspend fun stopIfIdle', transition);
    final transitionBody = manager.substring(transition, transitionEnd);
    final cancellationCheck =
        transitionBody.indexOf('currentCoroutineContext().ensureActive()');
    final planChange = transitionBody.indexOf('planLock.withLock { block() }');

    expect(batchProbe, contains('activeBatchProbeJobs.add(probeJob)'));
    expect(batchProbe, contains('activeBatchProbeJobs.remove(probeJob)'));
    expect(transition, greaterThan(0));
    expect(manager, contains('activeBatchProbeJobs.forEach { it.cancel() }'));
    expect(manager, contains('val jobs = planLock.withLock'));
    expect(manager, contains('jobs.joinAll()'));
    expect(cancellationCheck, greaterThan(0));
    expect(planChange, greaterThan(cancellationCheck));
    expect(
      manager,
      contains('suspend fun stopAll() = withBatchProbesStopped'),
    );
    expect(
      manager,
      contains('suspend fun applyPlan(planJson: String): String =\n'
          '        withBatchProbesStopped'),
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
