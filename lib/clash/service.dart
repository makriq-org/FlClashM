import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flclashx/clash/interface.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/core.dart';
import 'package:flclashx/product/platform/product_install_layout.dart';
import 'package:flclashx/product/runtime/desktop_process_supervisor.dart';
import 'package:flclashx/product/runtime/desktop_runtime_layout.dart';
import 'package:flclashx/product/runtime/desktop_runtime_node_bridge.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/product/runtime/windows_mihomo_runtime.dart';

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
  StreamIterator<String>? _socketIterator;
  Socket? _activeSocket;
  String? _controlToken;
  final _windowsMessages = WindowsCoreMessageBridge();
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
        shared: !Platform.isWindows,
      );
      serverCompleter.complete(server);
      await for (final socket in server) {
        unawaited(_acceptSocket(socket));
      }
    }, (error, stack) {
      commonPrint.log(error.toString());
      fileLogger.logCritical('uncaught core server error: $error', stack);
      // A failed ServerSocket.bind here never completes serverCompleter, so
      // preload()/reStart()/destroy() would await it forever (app stuck at
      // launch). Surface the failure to those awaiters so they degrade instead.
      if (!serverCompleter.isCompleted) {
        serverCompleter.completeError(error, stack);
      }
      if (error is SocketException) {
        globalState.showNotifier(error.toString());
      }
    });
  }

  Future<void> _acceptSocket(Socket socket) async {
    final iterator = StreamIterator<String>(socket
        .transform(uint8ListToListIntConverter)
        .transform(utf8.decoder)
        .transform(const LineSplitter()));
    var accepted = false;
    try {
      if (Platform.isWindows) {
        final expected = _controlToken;
        if (expected == null ||
            !await iterator.moveNext().timeout(const Duration(seconds: 3)))
          return;
        final hello = jsonDecode(iterator.current);
        if (hello is! Map ||
            !verifyWindowsControlHello(hello, expected) ||
            _controlToken != expected) {
          return;
        }
        socket.writeln(jsonEncode({
          'proof':
              windowsControlProof(expected, 'gui/v1', hello['nonce'] as String)
        }));
        await socket.flush();
        if (_controlToken != expected) {
          return;
        }
      }
      await _destroySocket();
      _activeSocket = socket;
      _socketIterator = iterator;
      accepted = true;
      socketCompleter.complete(socket);
      while (await iterator.moveNext()) {
        final decoded =
            Map<String, dynamic>.from(jsonDecode(iterator.current) as Map);
        handleResult(ActionResult.fromJson(
          Platform.isWindows && windowsMihomoRuntime.isActive
              ? await _windowsMessages.receive(decoded)
              : decoded,
        ));
      }
    } catch (error) {
      commonPrint.log('core socket failed: $error');
    } finally {
      if (!accepted) {
        await iterator.cancel();
        socket.destroy();
      } else if (identical(_activeSocket, socket)) {
        _onCoreLost('socket closed');
      }
    }
  }

  @override
  Future<void> reStart() async {
    if (isStarting == true) {
      return;
    }
    isStarting = true;
    try {
      if (process != null ||
          (Platform.isWindows && windowsMihomoRuntime.isActive)) {
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
      final homeDirPath = await appPath.homeDirPath;
      final environment = Map<String, String>.from(Platform.environment);
      environment['SAFE_PATHS'] = homeDirPath;

      if (Platform.isWindows) {
        _controlToken = createWindowsControlToken();
        environment['FLCLASHM_CONTROL_TOKEN'] = _controlToken!;
        if (windowsMihomoRuntime.preferService) {
          if (!await windowsMihomoRuntime.available()) {
            throw StateError('Системная служба Windows недоступна для TUN.');
          }
          await windowsMihomoRuntime.start(
              port: serverSocket.port, token: _controlToken!);
          return;
        }
      }
      final executable = await DesktopRuntimeLayout.current(
        dataRoot: homeDirPath,
      ).requireArtifact(ProductInstallLayout.mihomoArtifact);
      final handle = await desktopProcessSupervisor.spawn(
        identity: 'mihomo',
        executable: executable,
        arguments: [arg],
        environment: environment,
      );
      final started = handle.process;
      process = started;
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
    // Exit/restart destroys the complete desktop runtime ownership domain. A
    // core-only shutdown leaves built-in nodes and a resolver watcher alive.
    await shutdown();
    await desktopRuntimeNodeBridge.stopPlan();
    await desktopProcessSupervisor.stopAll();
    await _deleteSocketFile();
    return true;
  }

  @override
  Future<void> sendMessage(String message) async {
    try {
      final socket = await socketCompleter.future;
      socket.writeln(Platform.isWindows && windowsMihomoRuntime.isActive
          ? await _windowsMessages.prepare(message)
          : message);
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
    final iterator = _socketIterator;
    final socket = _activeSocket;
    _socketIterator = null;
    _activeSocket = null;
    socket?.destroy();
    await iterator?.cancel();
    _windowsMessages.clear();
    if (socketCompleter.isCompleted) {
      _flushPendingCompleters();
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
      await _stdoutSubscription?.cancel();
      _stdoutSubscription = null;
      await _stderrSubscription?.cancel();
      _stderrSubscription = null;
      await _destroySocket();
      if (Platform.isWindows) await windowsMihomoRuntime.stop();
      await desktopProcessSupervisor.stop('mihomo');
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
