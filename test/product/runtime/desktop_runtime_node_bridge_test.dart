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
      arguments: [
        '-u',
        '-c',
        'import socket\n'
            's=socket.socket()\n'
            's.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)\n'
            "s.bind(('127.0.0.1',$port))\n"
            's.listen()\n'
            'while True:\n'
            ' c,_=s.accept()\n'
            ' c.recv(3)\n'
            " c.sendall(b'\\x05\\x00')\n"
            ' c.close()\n',
      ],
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

Future<int> _reservePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
