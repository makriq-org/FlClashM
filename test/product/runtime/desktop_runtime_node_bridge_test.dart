import 'dart:io';

import 'package:flclashx/product/platform/product_install_layout.dart';
import 'package:flclashx/product/runtime/desktop_process_supervisor.dart';
import 'package:flclashx/product/runtime/desktop_runtime_layout.dart';
import 'package:flclashx/product/runtime/desktop_runtime_node_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('applies, reapplies and rolls back a real Linux node process', () async {
    if (!Platform.isLinux) return;
    final root = await Directory.systemTemp.createTemp('desktop-node-');
    addTearDown(() => root.delete(recursive: true));
    final layout = DesktopRuntimeLayout(
      installRoot: root.path,
      target: 'linux',
      architecture: 'x86_64',
      dataRoot: '${root.path}/data',
    );
    final executable = layout.artifactPath(
      ProductInstallLayout.naiveproxyArtifact,
    );
    await Directory(executable.substring(0, executable.lastIndexOf('/')))
        .create(recursive: true);
    final python = '${(await Process.run('which', ['python3'])).stdout}'.trim();
    await Link(executable).create(python);
    final port = await _reservePort();
    final supervisor = DesktopProcessSupervisor();
    await Directory('${layout.nodesRoot}/n1').create(recursive: true);
    final bridge = DesktopRuntimeNodeBridge(
      supervisor: supervisor,
      layout: layout,
    );
    addTearDown(bridge.stopPlan);

    final first = _node(
      layout: layout,
      executable: executable,
      port: port,
      revision: 'one',
      arguments: ['-u', '-c', _serverProgram(port)],
    );
    final ready = await bridge.applyPlan([first]);
    expect(ready.isReady, isTrue, reason: ready.message);
    expect(supervisor.childIdentities, ['node:n1']);

    final unchanged = await bridge.applyPlan([first]);
    expect(unchanged.isReady, isTrue);
    expect(supervisor.childIdentities, ['node:n1']);

    final failed = await bridge.applyPlan([
      _node(
        layout: layout,
        executable: executable,
        port: port,
        revision: 'two',
        arguments: const [
          '-c',
          'import time; time.sleep(30)',
        ],
      ),
    ]);
    expect(failed.status, 'failed');
    expect(failed.nodes.single['revision'], 'one');
    expect(supervisor.childIdentities, ['node:n1']);
  });

  test('fails the plan and stops remaining nodes when recovery spawn throws',
      () async {
    if (!Platform.isLinux) return;
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    var starts = 0;
    final supervisor = DesktopProcessSupervisor(
      startProcess: (
        executable,
        arguments, {
        workingDirectory,
        environment,
        includeParentEnvironment = true,
        runInShell = false,
        mode = ProcessStartMode.normal,
      }) {
        starts++;
        if (starts == 3) {
          return Future<Process>.error(StateError('spawn failed'));
        }
        return Process.start(
          executable,
          arguments,
          workingDirectory: workingDirectory,
          environment: environment,
          includeParentEnvironment: includeParentEnvironment,
          runInShell: runInShell,
          mode: mode,
        );
      },
    );
    final bridge = DesktopRuntimeNodeBridge(
      supervisor: supervisor,
      layout: fixture.layout,
    );
    addTearDown(bridge.stopPlan);

    final state = await bridge.applyPlan([
      fixture.node(
        id: 'crashing',
        type: 'naiveproxy',
        revision: 'one',
        arguments: _serverScript(fixture.ports[0], exitAfter: true),
      ),
      fixture.node(
        id: 'remaining',
        type: 'byedpi',
        revision: 'one',
        arguments: _serverScript(fixture.ports[1]),
      ),
    ]);
    expect(state.isReady, isTrue, reason: state.message);

    await _waitForFailed(bridge);
    expect((await bridge.readPlanState()).status, 'failed');
    expect(supervisor.childIdentities, isEmpty);
  });

  test(
      'fails the plan and stops remaining nodes when resolver rendering throws',
      () async {
    if (!Platform.isLinux) return;
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final supervisor = DesktopProcessSupervisor();
    final bridge = DesktopRuntimeNodeBridge(
      supervisor: supervisor,
      layout: fixture.layout,
    );
    addTearDown(bridge.stopPlan);
    final workDir = '${fixture.layout.nodesRoot}/crashing';
    final template = File('$workDir/resolver.template');
    await template.writeAsString('1.1.1.1\n');

    final state = await bridge.applyPlan([
      fixture.node(
        id: 'crashing',
        type: 'naiveproxy',
        revision: 'one',
        arguments: _serverScript(fixture.ports[0], exitAfter: true),
        resolverFile: {
          'template': 'resolver.template',
          'path': 'resolver.conf',
          'dependsOnSystemDns': false,
        },
      ),
      fixture.node(
        id: 'remaining',
        type: 'byedpi',
        revision: 'one',
        arguments: _serverScript(fixture.ports[1]),
      ),
    ]);
    expect(state.isReady, isTrue, reason: state.message);
    await template.writeAsString('# no resolvers\n');

    await _waitForFailed(bridge);
    expect((await bridge.readPlanState()).status, 'failed');
    expect(supervisor.childIdentities, isEmpty);
  });

  test('rerenders a system DNS resolver file when the desktop DNS changes',
      () async {
    if (!Platform.isLinux) return;
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    var dns = <String>['1.1.1.1'];
    final bridge = DesktopRuntimeNodeBridge(
      supervisor: DesktopProcessSupervisor(),
      layout: fixture.layout,
      readSystemDns: () async => dns,
      dnsPollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(bridge.stopPlan);
    final workDir = '${fixture.layout.nodesRoot}/remaining';
    await File('$workDir/resolver.template')
        .writeAsString('# @flclashm:system-dns\n');

    final state = await bridge.applyPlan([
      fixture.node(
        id: 'remaining',
        type: 'byedpi',
        revision: 'one',
        arguments: _serverScript(fixture.ports[1]),
        resolverFile: {
          'template': 'resolver.template',
          'path': 'resolver.conf',
          'dependsOnSystemDns': true,
        },
      ),
    ]);
    expect(state.isReady, isTrue, reason: state.message);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    dns = ['9.9.9.9'];

    final resolver = File('$workDir/resolver.conf');
    await _waitFor(
        () async => (await resolver.readAsString()).contains('9.9.9.9'));
  });
}

Map<String, dynamic> _node({
  required DesktopRuntimeLayout layout,
  required String executable,
  required int port,
  required String revision,
  required List<String> arguments,
}) =>
    <String, dynamic>{
      'nodeId': 'n1',
      'type': 'naiveproxy',
      'name': 'Node',
      'host': '127.0.0.1',
      'port': port,
      'executablePath': executable,
      'workingDirectory': '${layout.nodesRoot}/n1',
      'arguments': arguments,
      'revision': revision,
      'connectivityCheck': <String, dynamic>{
        'required': false,
        'startup-timeout': 1,
        'retry-interval': 0,
      },
    };

class _Fixture {
  _Fixture._(this.root, this.layout, this.ports);

  final Directory root;
  final DesktopRuntimeLayout layout;
  final List<int> ports;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('desktop-node-');
    final layout = DesktopRuntimeLayout(
      installRoot: root.path,
      target: 'linux',
      architecture: 'x86_64',
      dataRoot: '${root.path}/data',
    );
    final python = '${(await Process.run('which', ['python3'])).stdout}'.trim();
    for (final artifact in [
      ProductInstallLayout.naiveproxyArtifact,
      ProductInstallLayout.byedpiArtifact,
    ]) {
      final executable = layout.artifactPath(artifact);
      await Directory(executable.substring(0, executable.lastIndexOf('/')))
          .create(recursive: true);
      await Link(executable).create(python);
    }
    final ports = [await _reservePort(), await _reservePort()];
    for (final id in ['crashing', 'remaining']) {
      await Directory('${layout.nodesRoot}/$id').create(recursive: true);
    }
    return _Fixture._(root, layout, ports);
  }

  Future<void> dispose() => root.delete(recursive: true);

  Map<String, dynamic> node({
    required String id,
    required String type,
    required String revision,
    required List<String> arguments,
    Map<String, dynamic>? resolverFile,
  }) =>
      <String, dynamic>{
        'nodeId': id,
        'type': type,
        'name': id,
        'host': '127.0.0.1',
        'port': id == 'crashing' ? ports[0] : ports[1],
        'executablePath': layout.artifactPath(
          type == 'naiveproxy'
              ? ProductInstallLayout.naiveproxyArtifact
              : ProductInstallLayout.byedpiArtifact,
        ),
        'workingDirectory': '${layout.nodesRoot}/$id',
        'arguments': arguments,
        'revision': revision,
        if (resolverFile != null) 'resolverFile': resolverFile,
        'connectivityCheck': <String, dynamic>{
          'required': false,
          'startup-timeout': 1,
          'retry-interval': 0,
        },
      };
}

List<String> _serverScript(int port, {bool exitAfter = false}) => [
      '-u',
      '-c',
      _serverProgram(port, exitAfter: exitAfter),
    ];

String _serverProgram(int port, {bool exitAfter = false}) =>
    'import socket,time\n'
    's=socket.socket()\n'
    's.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)\n'
    "s.bind(('127.0.0.1',$port))\n"
    's.listen()\n'
    's.settimeout(.05)\n'
    'deadline=time.time()+.3\n'
    'while True:\n'
    ' try:\n'
    '  c,_=s.accept()\n'
    '  c.recv(3)\n'
    "  c.send(b'\\x05\\x00')\n"
    '  c.close()\n'
    ' except socket.timeout:\n'
    '  pass\n'
    '${exitAfter ? ' if time.time()>deadline: break\n' : ''}';

Future<void> _waitForFailed(DesktopRuntimeNodeBridge bridge) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if ((await bridge.readPlanState()).status == 'failed') return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('Runtime node plan did not enter failed state.');
}

Future<void> _waitFor(Future<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition did not become true.');
}

Future<int> _reservePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
