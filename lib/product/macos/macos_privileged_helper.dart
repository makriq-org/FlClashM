import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../../enum/enum.dart';
import '../../models/models.dart';
import '../runtime/desktop_helper_protocol.dart';
import '../runtime/engine_manager.dart';
import '../services/runtime_access_platform.dart';

const _helperChannelName = 'app.flclashm.client/privileged-helper';
const _runtimeInterface = 'FlClashM';
const _routeTransaction = 'app-session-route';
const _dnsTransaction = 'app-session-dns';

class MacosPrivilegedHelperTransport implements DesktopHelperTransport {
  const MacosPrivilegedHelperTransport({
    MethodChannel channel = const MethodChannel(_helperChannelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<bool> isReady() async {
    if (!Platform.isMacOS) return false;
    return await _channel.invokeMethod<bool>('status') ?? false;
  }

  Future<bool> install() async {
    if (!Platform.isMacOS) return false;
    return await _channel.invokeMethod<bool>('install') ?? false;
  }

  Future<bool> uninstall() async {
    if (!Platform.isMacOS) return false;
    return await _channel.invokeMethod<bool>('uninstall') ?? false;
  }

  Future<bool> ensureReady() async {
    try {
      if (await isReady()) return true;
    } on PlatformException {
      // An incompatible helper closes the IPC handshake. Re-installing the
      // fixed bundled helper is the only allowed recovery path.
    }
    return install();
  }

  @override
  Future<DesktopHelperResponse> send(DesktopHelperRequest request) async {
    if (!Platform.isMacOS) {
      return const DesktopHelperResponse(
        state: DesktopHelperState.unavailable,
        message: 'The macOS helper is unavailable on this platform.',
      );
    }
    final validation = DesktopHelperProtocol.validate(request);
    if (validation != null) {
      return DesktopHelperResponse(
        state: DesktopHelperState.failed,
        message: validation,
      );
    }
    final raw = await _channel.invokeMapMethod<String, Object?>('request', {
      'protocolVersion': request.protocolVersion,
      'installIdentity': request.installIdentity,
      'operation': _operationName(request.operation),
      if (request.runtimeArtifact != null)
        'runtimeArtifact': request.runtimeArtifact,
      'parameters': request.parameters,
    });
    final state = switch (raw?['state']) {
      'ready' => DesktopHelperState.ready,
      'applying' => DesktopHelperState.applying,
      'rollingBack' => DesktopHelperState.rollingBack,
      'unavailable' => DesktopHelperState.unavailable,
      _ => DesktopHelperState.failed,
    };
    return DesktopHelperResponse(
      state: state,
      message: raw?['message']?.toString() ?? '',
    );
  }

  static String _operationName(DesktopHelperOperation operation) =>
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

class MacosRuntimeAccessPolicy implements RuntimeAccessPlatformBridge {
  MacosRuntimeAccessPolicy({
    MacosPrivilegedHelperTransport transport =
        const MacosPrivilegedHelperTransport(),
  })  : _transport = transport,
        _client = DesktopHelperClient(transport: transport);

  final MacosPrivilegedHelperTransport _transport;
  final DesktopHelperClient _client;

  @override
  bool get isAndroid => false;

  @override
  Future<List<Package>> readPackages() => Future.value(const []);

  @override
  Future<ImageProvider?> readPackageIcon(String packageName) =>
      Future.value(null);

  @override
  String mergeVpnOptions(
    String optionsJson, {
    required AccessControl accessControl,
  }) =>
      optionsJson;

  @override
  Future<ProfileAccessSnapshot> readAppliedProfileAccess() =>
      Future.value(const ProfileAccessSnapshot.available(null));

  @override
  Future<ResolvedTunAccess> resolveTunAccess({
    required bool requestedTunEnable,
    required bool realTunEnable,
    required Future<void> Function() onAuthorizeRestart,
    required ValueChanged<bool> onResolvedTunEnable,
    Future<AuthorizeCode> Function()? authorizeCore,
  }) async {
    if (!requestedTunEnable) {
      onResolvedTunEnable(false);
      return const ResolvedTunAccess.proceed(enableTun: false);
    }
    if (!await _transport.ensureReady()) {
      onResolvedTunEnable(false);
      return const ResolvedTunAccess.abort();
    }
    onResolvedTunEnable(true);
    return const ResolvedTunAccess.proceed(enableTun: true);
  }

  @override
  Future<bool> startVpn({required AccessControl accessControl}) async {
    if (!await _transport.ensureReady()) return false;
    final tun = await _client.execute(
      const DesktopHelperRequest(
        operation: DesktopHelperOperation.tunOpen,
        parameters: {'interface': _runtimeInterface, 'mtu': 9000},
      ),
    );
    if (!tun.isSuccess) return false;

    final routes = await _client.execute(
      const DesktopHelperRequest(
        operation: DesktopHelperOperation.routeApply,
        parameters: {
          'interface': _runtimeInterface,
          'routes': ['0.0.0.0/1', '128.0.0.0/1'],
        },
      ),
      rollback: const DesktopHelperRequest(
        operation: DesktopHelperOperation.tunClose,
        parameters: {'interface': _runtimeInterface},
      ),
    );
    return routes.isSuccess;
  }

  @override
  Future<void> stopVpn() async {
    final failures = <String>[];
    for (final request in const [
      DesktopHelperRequest(
        operation: DesktopHelperOperation.routeRollback,
        parameters: {'transaction': _routeTransaction},
      ),
      DesktopHelperRequest(
        operation: DesktopHelperOperation.tunClose,
        parameters: {'interface': _runtimeInterface},
      ),
    ]) {
      final response = await _client.execute(request);
      if (!response.isSuccess) failures.add(response.message);
    }
    if (failures.isNotEmpty) {
      throw StateError('macOS network rollback failed: ${failures.join(' ')}');
    }
  }
}

class MacosSystemDns {
  MacosSystemDns({
    MacosPrivilegedHelperTransport transport =
        const MacosPrivilegedHelperTransport(),
  }) : _client = DesktopHelperClient(transport: transport);

  final DesktopHelperClient _client;

  Future<void> set({required bool restore}) async {
    if (!Platform.isMacOS) return;
    final request = restore
        ? const DesktopHelperRequest(
            operation: DesktopHelperOperation.dnsRollback,
            parameters: {'transaction': _dnsTransaction},
          )
        : const DesktopHelperRequest(
            operation: DesktopHelperOperation.dnsApply,
            parameters: {
              'interface': _runtimeInterface,
              'servers': ['1.1.1.1'],
            },
          );
    final response = await _client.execute(request);
    if (!response.isSuccess) throw StateError(response.message);
  }
}

const macosPrivilegedHelper = MacosPrivilegedHelperTransport();
final macosSystemDns = MacosSystemDns();
