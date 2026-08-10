import 'dart:convert';
import 'dart:io';

import 'desktop_helper_protocol.dart';
import 'desktop_runtime_layout.dart';
import '../platform/product_install_layout.dart';

/// Uses the fixed-layout helper only as an unprivileged Unix-socket client.
/// The root daemon validates SO_PEERCRED itself; Dart never opens a privileged
/// TCP listener and never passes an executable path to the helper protocol.
class LinuxDesktopHelperTransport implements DesktopHelperTransport {
  LinuxDesktopHelperTransport({DesktopRuntimeLayout? layout})
    : _layout = layout ?? DesktopRuntimeLayout.current();

  final DesktopRuntimeLayout _layout;

  @override
  Future<DesktopHelperResponse> send(DesktopHelperRequest request) =>
      _send(request, allowBootstrap: true);

  Future<DesktopHelperResponse> _send(
    DesktopHelperRequest request, {
    required bool allowBootstrap,
  }) async {
    if (_layout.target != ProductInstallLayout.linuxTarget) {
      return const DesktopHelperResponse(
        state: DesktopHelperState.unavailable,
        message: 'Linux helper transport is unavailable on this platform.',
      );
    }
    final bundledExecutable = await _layout.requireArtifact(
      ProductInstallLayout.helperArtifact,
    );
    final requestJson = jsonEncode({
      'protocolVersion': request.protocolVersion,
      'installIdentity': request.installIdentity,
      'operation': _operation(request.operation),
      if (request.runtimeArtifact != null)
        'runtimeArtifact': request.runtimeArtifact,
      'parameters': request.parameters,
    });
    final result = await _runRequest(
      bundledExecutable,
      const ['--request'],
      requestJson,
    );
    if (result.exitCode != 0) {
      if (allowBootstrap &&
          Platform.environment['APPIMAGE']?.trim().isNotEmpty == true) {
        final bootstrap = await Process.run(
          '/usr/bin/pkexec',
          [bundledExecutable, '--bootstrap'],
          runInShell: false,
        );
        if (bootstrap.exitCode == 0) {
          return _send(request, allowBootstrap: false);
        }
      } else if (allowBootstrap) {
        // DEB/RPM keep the daemon socket root-only. A request reaches it only
        // through the polkit path installed at this fixed location; package
        // membership never grants every local user helper access.
        final privileged = await _runRequest(
          '/usr/bin/pkexec',
          const ['/usr/libexec/flclashm-helper', '--request'],
          requestJson,
        );
        if (privileged.exitCode == 0) {
          return _decodeResponse(privileged.stdout);
        }
        return _unavailable(privileged.stderr);
      }
      return _unavailable(result.stderr);
    }
    return _decodeResponse(result.stdout);
  }

  Future<_HelperProcessResult> _runRequest(
    String executable,
    List<String> arguments,
    String requestJson,
  ) async {
    final process = await Process.start(
      executable,
      arguments,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    process.stdin.writeln(requestJson);
    await process.stdin.close();
    final output = await utf8.decoder.bind(process.stdout).join();
    final error = await utf8.decoder.bind(process.stderr).join();
    final exitCode = await process.exitCode;
    return _HelperProcessResult(
      exitCode: exitCode,
      stdout: output,
      stderr: error,
    );
  }

  DesktopHelperResponse _decodeResponse(String output) {
    try {
      final decoded = jsonDecode(output) as Map<String, dynamic>;
      return DesktopHelperResponse(
        state: DesktopHelperState.values.byName(decoded['state'] as String),
        message: decoded['message'] as String? ?? '',
      );
    } on Object {
      return const DesktopHelperResponse(
        state: DesktopHelperState.failed,
        message: 'Linux helper returned an invalid response.',
      );
    }
  }

  DesktopHelperResponse _unavailable(String error) => DesktopHelperResponse(
        state: DesktopHelperState.unavailable,
        message: error.trim().isEmpty
            ? 'Linux helper is unavailable.'
            : error.trim(),
      );

  static String _operation(DesktopHelperOperation operation) =>
      switch (operation) {
        DesktopHelperOperation.tunOpen => 'tunOpen',
        DesktopHelperOperation.tunClose => 'tunClose',
        DesktopHelperOperation.routeApply => 'routeApply',
        DesktopHelperOperation.routeRollback => 'routeRollback',
        DesktopHelperOperation.dnsApply => 'dnsApply',
        DesktopHelperOperation.dnsRollback => 'dnsRollback',
        DesktopHelperOperation.runtimeStart => 'runtimeStart',
        DesktopHelperOperation.runtimeStop => 'runtimeStop',
      };
}

class _HelperProcessResult {
  const _HelperProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}
