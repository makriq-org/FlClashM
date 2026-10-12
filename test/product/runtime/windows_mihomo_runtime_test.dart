import 'dart:convert';
import 'dart:io';

import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/platform/windows_runtime_access_policy.dart';
import 'package:flclashx/product/runtime/desktop_helper_protocol.dart';
import 'package:flclashx/product/runtime/windows_mihomo_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeHelper implements DesktopHelperTransport {
  final requests = <DesktopHelperRequest>[];
  bool failStop = false;
  bool failStart = false;
  bool failPing = false;
  @override
  Future<DesktopHelperResponse> send(DesktopHelperRequest request) async {
    requests.add(request);
    return DesktopHelperResponse(
      state: (failPing && request.operation == DesktopHelperOperation.ping) ||
              (failStop &&
                  request.operation == DesktopHelperOperation.runtimeStop) ||
              (failStart &&
                  request.operation == DesktopHelperOperation.runtimeStart)
          ? DesktopHelperState.failed
          : DesktopHelperState.ready,
      message: 'cleanup failed',
    );
  }
}

void main() {
  test('a helper refusal preserves the ordinary owner and its reason',
      () async {
    final helper = FakeHelper()..failPing = true;
    final runtime = WindowsMihomoRuntime(transport: helper);
    final policy = WindowsRuntimeAccessPolicy(runtime: runtime);
    var restarted = false;
    var resolved = false;
    await expectLater(
      policy.resolveTunAccess(
        requestedTunEnable: true,
        realTunEnable: false,
        onAuthorizeRestart: () async {
          restarted = true;
        },
        onResolvedTunEnable: (_) {
          resolved = true;
        },
      ),
      throwsA(isA<StateError>().having(
          (error) => error.message, 'reason', contains('cleanup failed'))),
    );
    expect(restarted, isFalse);
    expect(resolved, isFalse);
    expect(runtime.preferService, isFalse);
    expect(runtime.isActive, isFalse);
  });

  test('TUN switches ownership once and disabling it returns to the user',
      () async {
    final runtime = WindowsMihomoRuntime(transport: FakeHelper());
    final policy = WindowsRuntimeAccessPolicy(runtime: runtime);
    final resolved = <bool>[];
    var restarts = 0;
    Future<void> restart() async {
      restarts++;
      if (runtime.preferService) {
        await runtime.start(port: 49152, token: createWindowsControlToken());
      } else {
        await runtime.stop();
      }
    }

    final enabled = await policy.resolveTunAccess(
      requestedTunEnable: true,
      realTunEnable: false,
      onAuthorizeRestart: restart,
      onResolvedTunEnable: resolved.add,
    );
    expect(enabled.shouldProceed, isFalse);
    expect(runtime.isActive, isTrue);
    final unchanged = await policy.resolveTunAccess(
      requestedTunEnable: true,
      realTunEnable: true,
      onAuthorizeRestart: restart,
      onResolvedTunEnable: resolved.add,
    );
    expect(unchanged.shouldProceed, isTrue);
    expect(restarts, 1);
    final disabled = await policy.resolveTunAccess(
      requestedTunEnable: false,
      realTunEnable: true,
      onAuthorizeRestart: restart,
      onResolvedTunEnable: resolved.add,
    );
    expect(disabled.shouldProceed, isFalse);
    expect(runtime.isActive, isFalse);
    expect(runtime.preferService, isFalse);
    expect(restarts, 2);
    expect(resolved, [true, true, false]);
  });

  test('a refused start does not leave a fictitious lease', () async {
    final helper = FakeHelper()..failStart = true;
    final runtime = WindowsMihomoRuntime(transport: helper);
    await expectLater(
        runtime.start(port: 49152, token: createWindowsControlToken()),
        throwsStateError);
    expect(runtime.isActive, isFalse);
    await runtime.stop();
    expect(helper.requests, hasLength(1));
  });

  test('control proof authenticates both roles without disclosing the token',
      () {
    const token =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    const nonce =
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
    final proof = windowsControlProof(token, 'core/v1', nonce);
    expect(proof, isNot(contains(token)));
    expect(verifyWindowsControlHello({'nonce': nonce, 'proof': proof}, token),
        isTrue);
    expect(
        verifyWindowsControlHello({
          'nonce': nonce,
          'proof': windowsControlProof(token, 'gui/v1', nonce)
        }, token),
        isFalse);
    expect(verifyWindowsControlHello({'nonce': '', 'proof': proof}, token),
        isFalse);
  });

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
