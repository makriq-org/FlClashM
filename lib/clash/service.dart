import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flclashx/clash/interface.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/core.dart';
import 'package:flclashx/state.dart';

class ClashService extends ClashHandlerInterface {

  factory ClashService() {
    _instance ??= ClashService._internal();
    return _instance!;
  }

  ClashService._internal() {
    unawaited(_initServer());
    reStart();
  }
  static ClashService? _instance;

  Completer<ServerSocket> serverCompleter = Completer();

  Completer<Socket> socketCompleter = Completer();

  bool isStarting = false;

  Process? process;
  StreamSubscription? _socketSubscription;
  StreamSubscription? _stdoutSubscription;
  StreamSubscription? _stderrSubscription;

  Future<void> _initServer() async {
    runZonedGuarded(() async {
      final address = !Platform.isWindows
          ? InternetAddress(
              unixSocketPath,
              type: InternetAddressType.unix,
            )
          : InternetAddress(
              localhost,
              type: InternetAddressType.IPv4,
            );
      await _deleteSocketFile();
      final server = await ServerSocket.bind(
        address,
        0,
        shared: true,
      );
      serverCompleter.complete(server);
      await for (final socket in server) {
        await _destroySocket();
        socketCompleter.complete(socket);
        _socketSubscription = socket
            .transform(uint8ListToListIntConverter)
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
          (data) {
            handleResult(
              ActionResult.fromJson(
                json.decode(data.trim()),
              ),
            );
          },
        );
      }
    }, (error, stack) {
      commonPrint.log(error.toString());
      if (error is SocketException) {
        globalState.showNotifier(error.toString());
      }
    });
  }

  @override
  Future<void> reStart() async {
    if (isStarting == true) {
      return;
    }
    isStarting = true;
    socketCompleter = Completer();
    if (process != null) {
      await shutdown();
    }
    final serverSocket = await serverCompleter.future;
    final arg = Platform.isWindows
        ? "${serverSocket.port}"
        : serverSocket.address.address;
    if (Platform.isWindows && await system.checkIsAdmin()) {
      final isSuccess = await request.startCoreByHelper(arg);
      if (isSuccess) {
        isStarting = false;
        return;
      }
    }

    final homeDirPath = await appPath.homeDirPath;
    final environment = Map<String, String>.from(Platform.environment);
    environment['SAFE_PATHS'] = homeDirPath;

    process = await Process.start(
      appPath.corePath,
      [
        arg,
      ],
      environment: environment,
    );
    _stdoutSubscription = process?.stdout.listen((_) {});
    _stderrSubscription = process?.stderr.listen((e) {
      final error = utf8.decode(e);
      if (error.isNotEmpty) {
        commonPrint.log(error);
      }
    });
    isStarting = false;
  }

  @override
  Future<bool> destroy() async {
    final server = await serverCompleter.future;
    await server.close();
    await _deleteSocketFile();
    return true;
  }

  @override
  Future<void> sendMessage(String message) async {
    final socket = await socketCompleter.future;
    socket.writeln(message);
  }

  Future<void> _deleteSocketFile() async {
    if (!Platform.isWindows) {
      final file = File(unixSocketPath);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<void> _destroySocket() async {
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    if (socketCompleter.isCompleted) {
      _flushPendingCompleters();
      final lastSocket = await socketCompleter.future;
      await lastSocket.close();
      socketCompleter = Completer();
    }
  }

  void _flushPendingCompleters() {
    for (final entry in callbackCompleterMap.entries.toList()) {
      if (!entry.value.isCompleted) {
        entry.value.completeError(StateError('socket disconnected'));
      }
    }
    callbackCompleterMap.clear();
  }

  @override
  Future<bool> shutdown() async {
    if (Platform.isWindows) {
      await request.stopCoreByHelper();
    }
    await _stdoutSubscription?.cancel();
    _stdoutSubscription = null;
    await _stderrSubscription?.cancel();
    _stderrSubscription = null;
    await _destroySocket();
    process?.kill();
    process = null;
    return true;
  }

  @override
  Future<bool> preload() async {
    await serverCompleter.future;
    return true;
  }
}

final clashService = system.isDesktop ? ClashService() : null;
