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
      contains('val wasRunning = readStartTime(spec.nodeId) > 0L'),
      reason: 'a sleeping reserve node must not be started by a DNS change',
    );
    expect(processManager, contains('if (!wasRunning) continue'));
    expect(processManager, contains('stop(spec.nodeId)'));
    expect(processManager, contains('prepareNode(spec)'));
    expect(
      processManager,
      contains('lastStateJson = stateJson('),
      reason: 'a failed DNS-triggered restart must be visible to plan readers',
    );
    expect(
      processManager,
      contains('if (normalized == lastAppliedSystemDns)'),
      reason: 'a failed update must remain eligible for retry',
    );
    expect(
      networkObserve,
      contains('if (key == lastDnsKey)'),
      reason: 'duplicate network callbacks retry failed runtime-node updates',
    );
    expect(networkObserve, contains('updateRuntimeNodeDns(dns)'));
  });

  test('an unchanged resolver list does not restart the node', () {
    expect(
      processManager,
      contains('RuntimeNodeResolverFileRenderResult.UNCHANGED) continue'),
    );
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
}
