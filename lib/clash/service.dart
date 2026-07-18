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

  static const int _maxCrashRetries = 5;
  int _crashCount = 0;
  DateTime? _lastCrashTime;
  bool _recovering = false;
  // Set while an intentional teardown is in flight (shutdown/destroy, e.g. from
  // handleRestart/handleExit). The socket EOF that a deliberate stop produces
  // must NOT be mistaken for a core crash — otherwise the recovery path fires a
  // restart that races the app restart and leaves the core offline / the UI
  // wedged. On Windows the helper kills the core before we cancel the socket
  // subscription, so this window is real.
  bool _stopping = false;

  /// Set by AppController to a guarded restartCore(). A crashed desktop core is a
  /// dead child process whose whole state is gone (unlike Android, where :remote
  /// survives an AIDL rebind), so recovery must respawn AND re-init/re-apply — not
  /// just relaunch a blank core.
  Future<void> Function(String reason)? onCoreCrash;

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
            try {
              handleResult(
                ActionResult.fromJson(
                  json.decode(data.trim()),
                ),
              );
            } catch (e) {
              commonPrint.log('socket parse error: $e');
            }
          },
          onError: (Object e) {
            commonPrint.log('socket error: $e');
            _onCoreLost('socket error');
          },
          // EOF on the IPC socket means the core process died. An intentional
          // teardown cancels this subscription first, so onDone won't fire then.
          onDone: () => _onCoreLost('socket closed'),
        );
      }
    }, (error, stack) {
      commonPrint.log(error.toString());
      // A failed ServerSocket.bind here never completes serverCompleter, so
      // preload()/reStart()/destroy() would await it forever (app stuck at
      // launch). Surface the failure to those awaiters so they degrade instead.
      if (!serverCompleter.isCompleted) {
        serverCompleter.completeError(error);
      }
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
    try {
      if (process != null) {
        await shutdown();
      }
      // Swap in a downloaded core update before anything spawns the binary — a
      // spawn-first order either locks the exe (Windows) or leaves the whole
      // session on the old core (macOS/Linux).
      await coreUpdater.applyPending();
      // Reset AFTER shutdown(): shutdown -> _destroySocket flushes/closes the
      // live socket via its `socketCompleter.isCompleted` guard, which a fresh
      // (incomplete) completer would otherwise defeat.
      socketCompleter = Completer();
      final ServerSocket serverSocket;
      try {
        serverSocket = await serverCompleter.future;
      } catch (e) {
        commonPrint.log('reStart aborted: server unavailable: $e');
        return;
      }
      final arg = Platform.isWindows
          ? "${serverSocket.port}"
          : serverSocket.address.address;
      if (Platform.isWindows && await system.checkIsAdmin()) {
        final isSuccess = await request.startCoreByHelper(arg);
        if (isSuccess) {
          return;
        }
      }

      final homeDirPath = await appPath.homeDirPath;
      final environment = Map<String, String>.from(Platform.environment);
      environment['SAFE_PATHS'] = homeDirPath;

      final started = await Process.start(
        appPath.corePath,
        [
          arg,
        ],
        environment: environment,
      );
      process = started;
      _stdoutSubscription = started.stdout.listen((_) {});
      _stderrSubscription = started.stderr.listen((e) {
        final error = utf8.decode(e);
        if (error.isNotEmpty) {
          commonPrint.log(error);
        }
      });
      _watchProcess(started);
    } finally {
      isStarting = false;
    }
  }

  @override
  Future<bool> destroy() async {
    // No reset: destroy() only runs on paths that end the process
    // (handleRestart/handleExit), so any trailing socket EOF stays suppressed.
    _stopping = true;
    try {
      final server = await serverCompleter.future;
      await server.close();
    } catch (e) {
      // bind failed: there is no server to close, but still clean up the socket
      // file and resolve instead of hanging on serverCompleter forever.
      commonPrint.log('destroy: server unavailable: $e');
    }
    await _deleteSocketFile();
    return true;
  }

  @override
  Future<void> sendMessage(String message) async {
    try {
      final socket = await socketCompleter.future;
      socket.writeln(message);
    } catch (e) {
      // Writing to a dead socket used to throw into an unawaited future and
      // strand this call until its 30s safeFuture timeout. Fail it fast with the
      // typed default; the crash handler respawns the core.
      commonPrint.log('sendMessage error: $e');
      _failPendingCompleter(message, '$e');
    }
  }

  /// Watches a spawned core process; an exit while it is still the current
  /// process is an unexpected crash. Intentional shutdown()/reStart() nulls or
  /// replaces `process` before the kill, so those exits are ignored here. The
  /// Windows helper-started core has no local `process`, so the socket onDone
  /// path covers that case.
  void _watchProcess(Process p) {
    p.exitCode.then((code) {
      if (!identical(p, process)) return;
      commonPrint.log('core process exited unexpectedly (code=$code)');
      _onCoreLost('process exit $code');
    });
  }

  void _onCoreLost(String reason) {
    if (_recovering || isStarting || _stopping) return;
    _recovering = true;
    _flushPendingCompleters();
    unawaited(_handleCrashRestart(reason));
  }

  /// Backoff-guarded crash recovery mirroring the Android ClashLib path: at most
  /// [_maxCrashRetries] restarts, the counter resetting after 60s of stability.
  Future<void> _handleCrashRestart(String reason) async {
    try {
      final now = DateTime.now();
      if (_lastCrashTime != null &&
          now.difference(_lastCrashTime!).inSeconds > 60) {
        _crashCount = 0;
      }
      _lastCrashTime = now;
      _crashCount++;
      if (_crashCount > _maxCrashRetries) {
        commonPrint.log(
          'core crash loop: $_crashCount crashes, giving up until manual restart',
        );
        globalState.showNotifier('Core stopped unexpectedly');
        return;
      }
      final delayMs = 1000 * (1 << (_crashCount - 1)).clamp(1, 16);
      commonPrint.log(
        'core crash #$_crashCount/$_maxCrashRetries ($reason), '
        'retrying in ${delayMs}ms',
      );
      await Future.delayed(Duration(milliseconds: delayMs));
      final cb = onCoreCrash;
      if (cb != null) {
        await cb(reason);
      } else {
        // Pre-init phase (controller hasn't wired the callback yet): at least
        // respawn the process; there's no applied config to restore yet.
        await reStart();
      }
    } catch (e) {
      commonPrint.log('core crash restart error: $e');
    } finally {
      _recovering = false;
    }
  }

  void _failPendingCompleter(String message, String reason) {
    try {
      final decoded = json.decode(message);
      if (decoded is Map<String, dynamic>) {
        final id = decoded['id'] as String?;
        if (id != null) {
          final completer = callbackCompleterMap.remove(id);
          final def = callbackDefaultMap.remove(id);
          if (completer != null && !completer.isCompleted) {
            commonPrint.log('_failPendingCompleter: reason=$reason');
            completer.complete(def);
          }
        }
      }
    } catch (e) {
      commonPrint.log('_failPendingCompleter parse error: $e');
    }
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
        // Mirror _failPendingCompleter / handleResult: settle with the typed
        // default rather than completeError, which throws into callers and
        // causes TypeErrors/hangs on non-nullable completers.
        entry.value.complete(callbackDefaultMap[entry.key]);
      }
    }
    callbackCompleterMap.clear();
    callbackDefaultMap.clear();
  }

  @override
  Future<bool> shutdown() async {
    // Guard the whole teardown: the EOF from killing the core (helper stop on
    // Windows arrives before we cancel the subscription below) must not trip the
    // crash-recovery path into a restart that races an intentional stop/restart.
    _stopping = true;
    try {
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
    } finally {
      _stopping = false;
    }
  }

  @override
  Future<bool> preload() async {
    try {
      await serverCompleter.future;
    } catch (e) {
      // bind failed: resolve so main.dart's `await preload()` unblocks instead
      // of hanging the launch.
      commonPrint.log('preload: server unavailable: $e');
      return false;
    }
    return true;
  }
}

final clashService = system.isDesktop ? ClashService() : null;
