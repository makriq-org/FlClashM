import 'dart:convert';
import 'dart:io';

import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/runtime/desktop_helper_protocol.dart';
import 'package:flclashx/product/runtime/windows_mihomo_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeHelper implements DesktopHelperTransport {
  final requests = <DesktopHelperRequest>[];
  bool failStop = false;
  @override
  Future<DesktopHelperResponse> send(DesktopHelperRequest request) async {
    requests.add(request);
    return DesktopHelperResponse(
      state: failStop && request.operation == DesktopHelperOperation.runtimeStop
          ? DesktopHelperState.failed
          : DesktopHelperState.ready,
      message: 'cleanup failed',
    );
  }
}

void main() {
  test('runtime stop retains the lease until cleanup succeeds', () async {
    final helper = FakeHelper();
    final runtime = WindowsMihomoRuntime(transport: helper);
    final token = createWindowsControlToken();
    expect(token, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(await runtime.available(), isTrue);
    await runtime.start(port: 49152, token: token);
    helper.failStop = true;
    await expectLater(runtime.stop(), throwsStateError);
    expect(runtime.isActive, isTrue);
    helper.failStop = false;
    await runtime.stop();
    expect(runtime.isActive, isFalse);
    expect(helper.requests.last.parameters, {'runtimeToken': token});
  });

  test(
      'local providers are read by the GUI without changing the original setup',
      () async {
    final root = Directory.systemTemp.createTempSync('windows-provider-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File('${root.path}/provider.yaml')
      ..writeAsStringSync('proxies: []');
    final setup = SetupParams(config: {
      'proxy-providers': {
        'local': {'type': 'file', 'path': source.path}
      },
    }, selectedMap: const {}, testUrl: '');
    final prepared = await prepareWindowsServiceSetup(setup);
    expect(setup.config.containsKey('_flclashm-provider-files'), isFalse);
    final files = prepared.config['_flclashm-provider-files'] as Map;
    expect(utf8.decode(base64Decode(files['proxy-providers/local'] as String)),
        'proxies: []');
  });

  test('profile parsing transports bytes and download writes use GUI rights',
      () async {
    final root = Directory.systemTemp.createTempSync('windows-message-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File('${root.path}/profile.yaml')
      ..writeAsStringSync('mode: direct');
    final bridge = WindowsCoreMessageBridge();
    final parsed = jsonDecode(await bridge.prepare(jsonEncode(
        {'id': 'profile', 'method': 'getConfig', 'data': source.path}))) as Map;
    expect(
        utf8.decode(base64Decode((parsed['data'] as Map)['content'] as String)),
        'mode: direct');
    final target = '${root.path}/download.bin';
    final message = jsonDecode(await bridge.prepare(jsonEncode({
      'id': 'download',
      'method': 'tunnelHTTPRequest',
      'data': jsonEncode({'url': 'https://example.com', 'target-path': target}),
    }))) as Map;
    expect(
        jsonDecode(message['data'] as String), isNot(contains('target-path')));
    final result = await bridge.receive({
      'id': 'download',
      'data': {
        'status-code': 200,
        'body': base64Encode([1, 2, 3])
      }
    });
    expect(File(target).readAsBytesSync(), [1, 2, 3]);
    expect((result['data'] as Map)['written-len'], 3);
  });
}
