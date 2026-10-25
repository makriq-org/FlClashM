import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../common/common.dart';
import '../../l10n/l10n.dart';
import '../../state.dart';
import '../backend/backend.dart';
import '../diagnostics/product_diagnostic_exporter.dart';

/// Startup that keeps the UI reachable when the backend cannot be opened: a
/// recovery screen offers retry and log export while attempts continue in the
/// background. [run] completes once [initialize] has succeeded.
class BackendStartup {
  BackendStartup({
    required this.initialize,
    required this.present,
    this.reconnect,
    Duration Function(int failures)? retryDelay,
    void Function(String message)? log,
  }) : _retryDelay = retryDelay ?? _defaultRetryDelay,
       _log = log ?? commonPrint.log;

  final Future<void> Function() initialize;

  /// Shows the recovery screen after the first failed attempt.
  final FutureOr<void> Function(BackendStartup startup) present;

  /// Re-arms the backend binding, e.g. after a crash loop gave up.
  final void Function()? reconnect;
  final Duration Function(int failures) _retryDelay;
  final void Function(String message) _log;

  /// Last startup failure; shown by the recovery screen.
  final error = ValueNotifier<Object?>(null);

  /// Whether an attempt is running.
  final busy = ValueNotifier<bool>(false);
  final _ready = Completer<void>();
  Timer? _timer;
  int _failures = 0;

  Future<void> run() async {
    if (await _attempt()) return;
    await present(this);
    _schedule();
    await _ready.future;
  }

  /// User retry: attempts immediately.
  Future<void> retry() => _tryAgain();

  Future<bool> _attempt() async {
    busy.value = true;
    try {
      await initialize();
      return true;
    } catch (failure, stack) {
      _log('Startup attempt failed: $failure\n$stack');
      error.value = failure;
      _failures++;
      return false;
    } finally {
      busy.value = false;
    }
  }

  /// Every retry re-arms the binding: once a crash loop gave up, attempts
  /// without it fail immediately. The retry delay bounds the restart rate.
  Future<void> _tryAgain() async {
    if (busy.value || _ready.isCompleted) return;
    _timer?.cancel();
    reconnect?.call();
    if (await _attempt()) {
      _timer?.cancel();
      _ready.complete();
    } else {
      _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (_ready.isCompleted) return;
    _timer = Timer(_retryDelay(_failures), () => unawaited(_tryAgain()));
  }

  static Duration _defaultRetryDelay(int failures) =>
      Duration(seconds: min(30, 2 << min(failures, 4)));
}

/// Shows the recovery screen in the device language; the user's language
/// setting lives in the backend that could not be reached.
Future<void> presentBackendStartup(BackendStartup startup) async {
  await AppLocalizations.load(
    WidgetsBinding.instance.platformDispatcher.locale,
  );
  runApp(BackendStartupApp(startup: startup, exportLogs: exportStartupLogs));
}

/// Exports the local diagnostic archive without the backend.
Future<bool> exportStartupLogs({bool backendAvailable = false}) async {
  await fileLogger.flush();
  final info = await PackageInfo.fromPlatform();
  final data = await productDiagnosticExporter.buildArchive(
    DiagnosticExportContext(
      homeDirectory: await appPath.homeDirPath,
      appVersion: info.version,
      buildNumber: info.buildNumber,
      appTag: globalState.appVersionTag,
      coreVersion: globalState.coreVersion,
      runtime: {
        'uiAttached': backendAvailable,
        'backendAvailable': backendAvailable,
        if (backendAvailable)
          ...Map<String, Object?>.from(
            backendClient.snapshot['runtime'] as Map? ?? {},
          ),
      },
    ),
  );
  final fileName = utils.logFile.replaceFirst(RegExp(r'\.log$'), '.zip');
  return await picker.saveFile(fileName, data) != null;
}

class BackendStartupApp extends StatelessWidget {
  const BackendStartupApp({
    super.key,
    required this.startup,
    required this.exportLogs,
  });

  final BackendStartup startup;
  final Future<bool> Function() exportLogs;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.delegate.supportedLocales,
    theme: ThemeData(useMaterial3: true),
    darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
    home: _BackendStartupPage(startup: startup, exportLogs: exportLogs),
  );
}

class _BackendStartupPage extends StatelessWidget {
  const _BackendStartupPage({required this.startup, required this.exportLogs});

  final BackendStartup startup;
  final Future<bool> Function() exportLogs;

  Future<String> _exportText(AppLocalizations l10n) async {
    try {
      return await exportLogs() ? l10n.exportSuccess : '';
    } catch (error) {
      commonPrint.log('Startup log export failed: $error');
      return describeBackendError(error);
    }
  }

  Future<void> _export(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final text = await _exportText(AppLocalizations.of(context));
    if (text.isNotEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.cloud_off_outlined,
                  size: 56,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.backendStartupFailed,
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.backendStartupFailedDesc,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                ValueListenableBuilder<Object?>(
                  valueListenable: startup.error,
                  builder: (context, error, child) => error == null
                      ? const SizedBox.shrink()
                      : SelectableText(
                          describeBackendError(error),
                          style: theme.textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                ),
                const SizedBox(height: 24),
                ValueListenableBuilder<bool>(
                  valueListenable: startup.busy,
                  builder: (context, busy, child) => busy
                      ? const CircularProgressIndicator()
                      : FilledButton(
                          onPressed: () => unawaited(startup.retry()),
                          child: Text(l10n.retry),
                        ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => unawaited(_export(context)),
                  child: Text(l10n.exportLogs),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
