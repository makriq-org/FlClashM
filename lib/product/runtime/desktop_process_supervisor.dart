import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flclashx/common/common.dart';

const desktopProcessOutputLimit = 64 * 1024;

class DesktopProcessHandle {
  DesktopProcessHandle({
    required this.identity,
    required this.process,
    required this.output,
  });

  final String identity;
  final Process process;
  final DesktopBoundedOutput output;
}

class DesktopBoundedOutput {
  DesktopBoundedOutput({this.limit = desktopProcessOutputLimit});

  final int limit;
  String _value = '';

  String get value => _value;

  void add(List<int> bytes) {
    var text = utf8.decode(bytes, allowMalformed: true);
    text = _redact(text);
    _value += text;
    if (_value.length > limit) {
      _value = _value.substring(_value.length - limit);
    }
  }

  static String _redact(String value) => value
      .replaceAll(
        RegExp(
          r'(password|token|secret|authorization)\s*[:=]\s*\S+',
          caseSensitive: false,
        ),
        r'$1=<redacted>',
      )
      .replaceAll(
        RegExp(r'://([^/@:\s]+):([^/@\s]+)@', caseSensitive: false),
        '://<redacted>@',
      );
}

/// Single owner for every desktop child process. Platform helpers may own
/// privileged state, but the unprivileged app never delegates arbitrary spawn.
class DesktopProcessSupervisor {
  DesktopProcessSupervisor({
    this.startProcess = Process.start,
    this.socketConnect = Socket.connect,
  });

  final Future<Process> Function(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment,
    bool runInShell,
    ProcessStartMode mode,
  }) startProcess;
  final Future<Socket> Function(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort,
    Duration? timeout,
  }) socketConnect;

  final Map<String, DesktopProcessHandle> _children = {};
  final Map<String, String> _lastOutput = {};
  Future<void> _mutation = Future<void>.value();

  Iterable<String> get childIdentities => _children.keys;

  String outputFor(String identity) =>
      _children[identity]?.output.value ?? _lastOutput[identity] ?? '';

  Future<DesktopProcessHandle> spawn({
    required String identity,
    required String executable,
    required List<String> arguments,
    String? workingDirectory,
    Map<String, String>? environment,
    FutureOr<void> Function(int exitCode)? onUnexpectedExit,
  }) =>
      _serialize(() async {
        await _stopLocked(identity);
        final output = DesktopBoundedOutput();
        final process = await startProcess(
          executable,
          List<String>.unmodifiable(arguments),
          workingDirectory: workingDirectory,
          environment: environment,
          includeParentEnvironment: true,
          runInShell: false,
          mode: ProcessStartMode.normal,
        );
        final handle = DesktopProcessHandle(
          identity: identity,
          process: process,
          output: output,
        );
        _children[identity] = handle;
        process.stdout.listen(output.add);
        process.stderr.listen(output.add);
        unawaited(
          process.exitCode.then((code) {
            if (identical(_children[identity], handle)) {
              _children.remove(identity);
              _lastOutput[identity] = handle.output.value;
              commonPrint.log(
                'Desktop runtime process `$identity` exited (code=$code).',
              );
              if (onUnexpectedExit != null) {
                unawaited(Future<void>.sync(() => onUnexpectedExit(code)));
              }
            }
          }),
        );
        return handle;
      });

  Future<void> stop(String identity) => _serialize(() => _stopLocked(identity));

  Future<void> stopWhere(bool Function(String identity) predicate) =>
      _serialize(() async {
        for (final identity in _children.keys.where(predicate).toList()) {
          await _stopLocked(identity);
        }
      });

  Future<void> stopAll() => stopWhere((_) => true);

  Future<bool> waitForSocks({
    required String identity,
    required String host,
    required int port,
    required Duration timeout,
    Duration retryInterval = const Duration(milliseconds: 100),
  }) async {
    final deadline = DateTime.now().add(timeout);
    do {
      if (!_children.containsKey(identity)) return false;
      Socket? socket;
      try {
        socket = await socketConnect(
          host,
          port,
          timeout: const Duration(milliseconds: 500),
        );
        socket.add(const <int>[5, 1, 0]);
        await socket.flush();
        final reply = await socket.first.timeout(
          const Duration(milliseconds: 500),
        );
        if (reply.length >= 2 && reply[0] == 5 && reply[1] == 0) return true;
      } catch (_) {
        // Retry until the monotonic startup budget is exhausted.
      } finally {
        await socket?.close();
      }
      await Future<void>.delayed(retryInterval);
    } while (DateTime.now().isBefore(deadline));
    return false;
  }

  Future<bool> probeSocksHttp({
    required String host,
    required int port,
    required Uri uri,
    required Duration timeout,
  }) async {
    final addresses = await InternetAddress.lookup(uri.host).timeout(timeout);
    if (addresses.isEmpty || addresses.any((item) => !isPublic(item))) {
      return false;
    }
    Socket? socket;
    try {
      socket = await socketConnect(host, port, timeout: timeout);
      socket.add(const <int>[5, 1, 0]);
      await socket.flush();
      final greeting = await socket.first.timeout(timeout);
      if (greeting.length < 2 || greeting[1] != 0) return false;
      final address = addresses.first;
      final targetPort =
          uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
      final request = BytesBuilder()
        ..add(const [5, 1, 0])
        ..add([address.type == InternetAddressType.IPv4 ? 1 : 4])
        ..add(address.rawAddress)
        ..add([(targetPort >> 8) & 0xff, targetPort & 0xff]);
      socket.add(request.takeBytes());
      await socket.flush();
      final connected = await socket.first.timeout(timeout);
      if (connected.length < 2 || connected[1] != 0) return false;
      // A successful SOCKS CONNECT is the mandatory path check. TLS and HTTP
      // remain owned by the regular tunnel health probe.
      return true;
    } catch (_) {
      return false;
    } finally {
      await socket?.close();
    }
  }

  static bool isPublic(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return bytes[0] != 10 &&
          bytes[0] != 127 &&
          !(bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) &&
          !(bytes[0] == 192 && bytes[1] == 168) &&
          !(bytes[0] == 169 && bytes[1] == 254);
    }
    return !(bytes.every((value) => value == 0) ||
        bytes[0] == 0xff ||
        (bytes[0] & 0xfe) == 0xfc ||
        (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80));
  }

  Future<void> _stopLocked(String identity) async {
    final handle = _children.remove(identity);
    if (handle == null) return;
    handle.process.kill(ProcessSignal.sigterm);
    try {
      await handle.process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      handle.process.kill(ProcessSignal.sigkill);
      await handle.process.exitCode.timeout(const Duration(seconds: 1));
    }
    _lastOutput[identity] = handle.output.value;
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _mutation = _mutation.catchError((_) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

final desktopProcessSupervisor = DesktopProcessSupervisor();
