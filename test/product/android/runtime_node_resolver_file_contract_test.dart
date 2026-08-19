import 'dart:io';

import 'package:flclashx/product/compile/stormdns_resolver_sources.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Android sources are never compiled or unit-tested by CI, so the
/// invariants the Dart side depends on are pinned here.
void main() {
  final resolverFile = File(
    'android/service/src/main/kotlin/com/follow/clashx/service/'
    'RuntimeNodeResolverFile.kt',
  ).readAsStringSync();
  final processManager = File(
    'android/service/src/main/kotlin/com/follow/clashx/service/'
    'RuntimeNodeProcessManager.kt',
  ).readAsStringSync();
  final networkObserve = File(
    'android/service/src/main/kotlin/com/follow/clashx/service/modules/'
    'NetworkObserveModule.kt',
  ).readAsStringSync();

  test('the system-DNS placeholder is identical on both sides', () {
    expect(
      resolverFile,
      contains('const val SYSTEM_DNS_PLACEHOLDER = '
          '"$stormDnsSystemDnsPlaceholder"'),
    );
  });

  test('the runtime-node contract stays node-type agnostic', () {
    for (final source in [resolverFile, processManager, networkObserve]) {
      expect(source.toLowerCase(), isNot(contains('stormdns')));
    }
    for (final source in [resolverFile, processManager]) {
      expect(source, isNot(contains('spec.type ==')));
      expect(source, isNot(contains('type == "')));
    }
  });

  test('the node spec parses the generic launch fields', () {
    expect(
        processManager, contains('val resolverFile: RuntimeNodeResolverFile?'));
    expect(processManager, contains('RuntimeNodeResolverFile.fromJson('));
    expect(processManager, contains('optJSONArray("startupFailurePatterns")'));
    expect(resolverFile, contains('value.optString("template", "")'));
    expect(resolverFile, contains('value.optString("path", "")'));
    expect(resolverFile, contains('optBoolean("dependsOnSystemDns", false)'));
    expect(resolverFile, contains('optJSONArray("resetPaths")'));
    expect(resolverFile, contains('optString("systemDnsMode", "resolver-list")'));
  });

  test('runtime-node stdin stays open for lifetime-controlled clients', () {
    expect(processManager, isNot(contains('closeStdin')));
    expect(processManager, isNot(contains('if (spec.closeStdin)')));
  });

  test('declared native startup failures stop listener waiting early', () {
    expect(processManager, contains('fun firstLineContaining('));
    expect(
      processManager,
      contains('reported a startup failure:'),
    );
    expect(
      processManager,
      contains('firstLineContaining(spec.startupFailurePatterns)'),
    );
  });

  test('the resolver file is rendered before the process is launched', () {
    final renderIndex = processManager.indexOf(
      'RuntimeNodeResolverFileWriter.render(',
    );
    final launchIndex = processManager.indexOf('ProcessBuilder(');
    expect(renderIndex, greaterThan(0));
    expect(launchIndex, greaterThan(0));
    expect(
      renderIndex,
      lessThan(launchIndex),
      reason: 'a node must never start against a stale resolver list',
    );
  });

  test('generated paths are confined to the node working directory', () {
    expect(resolverFile, contains('fun resolveInside('));
    expect(resolverFile, contains('canonicalFile'));
    expect(
      resolverFile,
      contains('resolvedPath.startsWith(rootPath + File.separator)'),
    );
    expect(resolverFile, contains('resetDeclaredPaths('));
  });

  test('an absolute declared path is refused, not re-rooted', () {
    // `File(parent, child)` silently re-roots an absolute child inside the
    // parent. That is still contained, but it hides a malformed declaration,
    // so absolute paths are rejected outright.
    expect(
      resolverFile,
      contains('if (File(relativePath).isAbsolute) return null'),
    );
    expect(resolverFile, contains('if (relativePath.isBlank()) return null'));
  });

  test('the resolver file is written atomically', () {
    expect(resolverFile, contains('.tmp'));
    expect(resolverFile, contains('renameTo(target)'));
    expect(resolverFile, isNot(contains('target.writeText(rendered)')));
  });

  test('a DNS change rewrites, resets caches, and restarts only dependents',
      () {
    expect(processManager, contains('suspend fun updateSystemDns('));
    expect(
      processManager,
      contains('withBatchProbesStopped'),
      reason: 'DNS updates must not race a runtime-plan transition',
    );
    expect(
      processManager,
      contains('it.resolverFile?.dependsOnSystemDns == true'),
      reason: 'only nodes that declared the dependency are touched',
    );
    expect(processManager, contains('resetDeclaredPaths'));
    expect(resolverFile, contains('deleteRecursively()'));
    expect(
      processManager,
      contains('readStartTime(spec.nodeId) > 0L'),
      reason: 'a sleeping reserve node must not be started by a DNS change',
    );
    expect(processManager, contains('if (!wasRunning) continue'));
    expect(processManager, contains('stop(spec.nodeId)'));
    expect(processManager, contains('prepareNode('));
    expect(
      processManager,
      contains('lastStateJson = stateJson('),
      reason: 'a failed DNS-triggered restart must be visible to plan readers',
    );
    expect(
      processManager,
      contains('normalized == lastAppliedSystemDns'),
      reason: 'a failed update must remain eligible for retry',
    );
    expect(
      networkObserve,
      contains('if (key == lastDnsKey)'),
      reason: 'duplicate network callbacks retry failed runtime-node updates',
    );
    expect(networkObserve, contains('updateRuntimeNodeDns(dns)'));
  });

  test('a DNS change never makes a profile apply wait for a node restart', () {
    // A DNS pass runs under the plan lock, so `applyPlan` can only be prompt if
    // it preempts the pass first.
    final cancelIndex = processManager.indexOf('cancelSystemDnsWork()');
    final applyIndex = processManager.indexOf('applyPlanLocked(planJson)');
    expect(cancelIndex, greaterThan(0));
    expect(
      applyIndex,
      greaterThan(cancelIndex),
      reason: 'the running DNS pass is cancelled before the lock is taken',
    );
    expect(
      processManager,
      contains('systemDnsPassJobs.forEach { it.cancel() }'),
      reason: 'cancel, never join: the pass may hold the lock we want',
    );
    expect(
      processManager,
      isNot(contains('systemDnsPassJobs.forEach { it.cancelAndJoin() }')),
    );
    expect(
      processManager,
      contains('if (error is CancellationException) throw error'),
      reason: 'a preempted restart must unwind, not be reported as a failure',
    );
    expect(
      processManager,
      contains('DNS_UPDATE_BUDGET_MILLIS'),
      reason: 'no pass may hold the plan lock without a ceiling',
    );
    expect(
      processManager,
      contains('startupTimeoutMillis: Long = spec.connectivityCheck'),
      reason: 'the restart budget is a parameter, not a mutated spec',
    );
  });

  test('a DNS callback that changes nothing never takes the plan lock', () {
    // `runSystemDnsPass` takes the plan transition lock and cancels every batch
    // probe in flight before `applySystemDns` gets to notice that nothing
    // changed, so a redundant callback used to abort a running auto-probe.
    final updateIndex = processManager.indexOf('suspend fun updateSystemDns(');
    final unchangedIndex = processManager.indexOf(
      'normalized == lastAppliedSystemDns &&\n'
      '            pendingSystemDnsRestarts.isEmpty() &&\n'
      '            pendingSystemDnsResets.isEmpty()',
    );
    final dependentsIndex =
        processManager.indexOf('if (!hasSystemDnsDependents) {');
    final passIndex = processManager.indexOf('runSystemDnsPass(normalized)');
    expect(updateIndex, greaterThan(0));
    expect(unchangedIndex, greaterThan(updateIndex));
    expect(dependentsIndex, greaterThan(unchangedIndex));
    expect(
      passIndex,
      greaterThan(dependentsIndex),
      reason: 'the cheap check must come before the lock is taken',
    );
    expect(
      'normalized == lastAppliedSystemDns'.allMatches(processManager).length,
      2,
      reason: 'the fast path is an optimisation; the authoritative check stays',
    );
  });

  test('the system-DNS dependency flag cannot drift from the plan', () {
    expect(
      processManager,
      contains('@Volatile private var hasSystemDnsDependents'),
      reason: 'the fast path reads it without holding the plan lock',
    );
    expect(
      RegExp(r'(?<!var )hasSystemDnsDependents =')
          .allMatches(processManager)
          .length,
      1,
      reason: 'only the `activePlan` setter may write it',
    );
    final setterIndex = processManager.indexOf('private var activePlan =');
    final writeIndex = processManager.indexOf('hasSystemDnsDependents =');
    final applyIndex = processManager.indexOf('activePlan = LinkedHashMap(');
    expect(setterIndex, greaterThan(0));
    expect(writeIndex, greaterThan(setterIndex));
    expect(
      applyIndex,
      greaterThan(writeIndex),
      reason: 'every plan assignment goes through the setter that maintains it',
    );
  });

  test('a failed DNS update retries without a new network callback', () {
    expect(processManager, contains('private fun scheduleSystemDnsRetry('));
    expect(processManager, contains('MAX_SYSTEM_DNS_RETRIES'));
    expect(
      processManager,
      contains('pendingSystemDnsRestarts'),
      reason: 'a later pass renders the same bytes, so the restart is tracked',
    );
    expect(
      processManager,
      contains('pendingSystemDnsResets'),
      reason: 'a sleeping node must retry a failed cache reset too',
    );
    expect(
      processManager,
      contains('systemDnsRetryJobs[retryTarget]?.isActive == true'),
      reason: 'duplicate callbacks must share one retry loop',
    );
    expect(
      processManager,
      contains('systemDnsRetryJobs.values.forEach { it.cancel() }'),
      reason: 'a plan transition must retain and cancel every retry loop',
    );
    expect(
      processManager,
      contains('systemDnsWorkEpoch != expectedEpoch'),
      reason: 'a retry for a superseded list must abandon itself',
    );
    expect(
      processManager,
      contains('if (!restartPending && !resetPending) continue'),
      reason: 'an UNCHANGED render must not strand work the retry owes',
    );
    expect(
      processManager,
      contains('nodeId !in pendingSystemDnsResets'),
      reason:
          'a plan transition must finish a cache reset before reusing a node',
    );
  });

  test('one unrelated node does not fail the whole DNS update', () {
    expect(
      processManager,
      contains('val failure = touched.values.firstOrNull { !it.ready }'),
      reason: 'plan status follows the nodes this pass actually touched',
    );
    expect(
      processManager,
      isNot(contains('val failure = outcomes.firstOrNull { !it.ready }\n'
          '        lastStateJson')),
      reason: 'status must not be derived from every node in the plan',
    );
    expect(
      processManager,
      contains('touched[spec.nodeId] ?: untouchedOutcome(spec)'),
      reason: 'an untouched failure stays visible instead of being masked',
    );
  });

  test('an unusable resolver file says which of the two causes it was', () {
    expect(
      resolverFile,
      contains('SYSTEM_DNS_UNAVAILABLE'),
      reason: 'an auto-activated node wakes up exactly when DNS is missing',
    );
    expect(
      resolverFile,
      contains('wantsSystemDns && systemDns.isEmpty()'),
    );
    expect(
      processManager,
      contains('private fun resolverRenderFailureMessage('),
    );
    expect(
      processManager,
      contains('startFailures.remove(spec.nodeId)'),
      reason: 'the reason must reach the plan state, not just the log',
    );
    expect(
      processManager,
      contains('private fun failStart('),
    );
  });

  test('a system resolver with an IPv6 zone never reaches the file', () {
    expect(resolverFile, contains('fun sanitize('));
    expect(resolverFile, contains("!it.contains('%')"));
    expect(
      processManager,
      contains('SystemDnsReader.sanitize(dnsServers)'),
      reason: 'the platform callback path goes through the same filter',
    );
    expect(
      resolverFile,
      contains(
          'sanitize(linkProperties.dnsServers.mapNotNull { it.hostAddress })'),
      reason: 'the cold-start reader uses it too',
    );
  });

  test('an unchanged resolver list does not restart the node', () {
    // The only way past an UNCHANGED render is a restart a previous pass
    // already owed for this node; a healthy node is skipped outright.
    final unchangedIndex = processManager.indexOf(
      'RuntimeNodeResolverFileRenderResult.UNCHANGED -> {',
    );
    final guardIndex = processManager
        .indexOf('if (!restartPending && !resetPending) continue');
    final changedIndex = processManager.indexOf(
      'RuntimeNodeResolverFileRenderResult.CHANGED -> {',
    );
    expect(unchangedIndex, greaterThan(0));
    expect(guardIndex, greaterThan(unchangedIndex));
    expect(changedIndex, greaterThan(guardIndex));
    expect(
      resolverFile,
      contains('RuntimeNodeResolverFileRenderResult.UNCHANGED'),
    );
  });

  test('cold start invalidates caches when the generated list changes', () {
    final renderIndex = processManager.lastIndexOf(
      'RuntimeNodeResolverFileWriter.render(',
    );
    final resetIndex = processManager.lastIndexOf(
      'RuntimeNodeResolverFileWriter.resetDeclaredPaths(',
    );
    final launchIndex = processManager.indexOf('ProcessBuilder(');
    expect(renderIndex, greaterThan(0));
    expect(resetIndex, greaterThan(renderIndex));
    expect(launchIndex, greaterThan(resetIndex));
    expect(
      processManager,
      contains('RuntimeNodeResolverFileRenderResult.FAILED'),
      reason: 'a node must not start against an old or missing resolver file',
    );
  });

  test('the network observer forwards DNS changes to runtime nodes', () {
    expect(
      networkObserve,
      contains('RuntimeNodeProcessManager.updateSystemDns(dns)'),
    );
    final emptyIndex = networkObserve.indexOf('if (dns.isEmpty()) {');
    final forwardIndex =
        networkObserve.indexOf('updateRuntimeNodeDns(dns)', emptyIndex);
    final returnIndex = networkObserve.indexOf('return false', emptyIndex);
    expect(emptyIndex, greaterThan(0));
    expect(forwardIndex, greaterThan(emptyIndex));
    expect(
      returnIndex,
      greaterThan(forwardIndex),
      reason: 'an empty list must invalidate stale runtime-node DNS',
    );
    expect(
      processManager,
      contains('@Volatile private var latestSystemDns: List<String>? = null'),
      reason: 'known-empty DNS must not be mistaken for an unseeded cache',
    );
    expect(processManager, contains('if (cached != null) return cached'));
  });

  test('Android keeps the system-DNS expansion inside the Dart reserve', () {
    expect(
      resolverFile,
      contains(
        'const val MAX_SYSTEM_DNS_SERVERS = '
        '$stormDnsSystemDnsReservedHosts',
      ),
    );
    expect(resolverFile, contains('.take(MAX_SYSTEM_DNS_SERVERS)'));
    expect(
      networkObserve,
      contains('SystemDnsReader.sanitize('),
      reason: 'live callbacks and cold start must apply the same ceiling',
    );
  });

  test('cold start can read system DNS without a Flutter process', () {
    expect(resolverFile, contains('object SystemDnsReader'));
    expect(resolverFile, contains('NET_CAPABILITY_NOT_VPN'));
    expect(processManager, contains('private fun currentSystemDns()'));
    expect(
      processManager,
      contains('SystemDnsReader.read()'),
      reason: 'the plan is applied at cold start before any observer installs',
    );
  });

  test('de-duplication keeps the first entry for an address', () {
    expect(
        resolverFile, contains('if (!seen.add(resolverKey(entry))) continue'));
    expect(resolverFile, contains('private fun resolverKey('));
  });

  test('single-endpoint mode stays generic and fails closed', () {
    expect(resolverFile, contains('SINGLE_HOST_PORT'));
    expect(resolverFile, contains('SYSTEM_DNS_VALUE_PLACEHOLDER'));
    expect(resolverFile, contains('else -> INVALID'));
    expect(resolverFile, contains('.count { it == placeholder } != 1'));
  });

  test('a failed DNS restart restores the previous generated artifact', () {
    expect(processManager, contains('rollbackSystemDnsNode('));
    expect(processManager, contains('RuntimeNodeResolverFileWriter.snapshot('));
    expect(processManager, contains('RuntimeNodeResolverFileWriter.restore('));
    expect(processManager, contains('renderResolverFile = false'));
    expect(
      processManager,
      contains('minOf(spec.connectivityCheck.startupTimeoutMillis, budget / 2)'),
      reason: 'the update attempt must reserve time for rollback',
    );
    expect(
      processManager,
      contains('val rollbackBudget = deadline - SystemClock.elapsedRealtime()'),
      reason: 'rollback must use only the time left in the DNS pass',
    );
    expect(
      processManager,
      contains('touched[spec.nodeId] = rollback.copy(message = rollbackFailure)'),
      reason: 'a rollback failure must replace the original update error',
    );
    expect(
      processManager,
      contains('pendingSystemDnsRestarts.add(spec.nodeId)'),
      reason: 'the new DNS must remain pending after the old process returns',
    );
  });
}
