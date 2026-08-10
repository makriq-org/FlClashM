import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/product_install_layout.dart';

const desktopHelperProtocolVersion = 1;

enum DesktopHelperOperation {
  tunOpen,
  tunClose,
  routeApply,
  routeRollback,
  dnsApply,
  dnsRollback,
  runtimeStart,
  runtimeStop,
}

enum DesktopHelperState { unavailable, ready, applying, rollingBack, failed }

@immutable
class DesktopHelperRequest {
  const DesktopHelperRequest({
    required this.operation,
    this.protocolVersion = desktopHelperProtocolVersion,
    this.installIdentity = ProductInstallLayout.desktopApplicationId,
    this.runtimeArtifact,
    this.parameters = const {},
  });

  final int protocolVersion;
  final String installIdentity;
  final DesktopHelperOperation operation;
  final String? runtimeArtifact;
  final Map<String, Object?> parameters;
}

@immutable
class DesktopHelperResponse {
  const DesktopHelperResponse({required this.state, this.message = ''});

  final DesktopHelperState state;
  final String message;

  bool get isSuccess => state == DesktopHelperState.ready;
}

/// The helper accepts a closed, versioned vocabulary. In particular, callers
/// cannot supply executable paths, command lines, environment variables or
/// shell fragments.
class DesktopHelperProtocol {
  const DesktopHelperProtocol._();

  static const _runtimeArtifacts = <String>{
    ProductInstallLayout.mihomoArtifact,
    ProductInstallLayout.naiveproxyArtifact,
    ProductInstallLayout.olcrtcArtifact,
    ProductInstallLayout.byedpiArtifact,
    ProductInstallLayout.stormdnsArtifact,
  };

  static const _requiredParameters = <DesktopHelperOperation, Set<String>>{
    DesktopHelperOperation.tunOpen: {'interface', 'mtu'},
    DesktopHelperOperation.tunClose: {'interface'},
    DesktopHelperOperation.routeApply: {'interface', 'routes'},
    DesktopHelperOperation.routeRollback: {'transaction'},
    DesktopHelperOperation.dnsApply: {'interface', 'servers'},
    DesktopHelperOperation.dnsRollback: {'transaction'},
    DesktopHelperOperation.runtimeStart: {'runtimeToken'},
    DesktopHelperOperation.runtimeStop: {'runtimeToken'},
  };

  static String? validate(DesktopHelperRequest request) {
    if (request.protocolVersion != desktopHelperProtocolVersion) {
      return 'Unsupported desktop helper protocol version.';
    }
    if (request.installIdentity != ProductInstallLayout.desktopApplicationId) {
      return 'Unexpected desktop install identity.';
    }
    final required = _requiredParameters[request.operation]!;
    if (request.parameters.keys.length != required.length ||
        !request.parameters.keys.toSet().containsAll(required) ||
        request.parameters.keys.any(_looksExecutable)) {
      return 'Desktop helper request has an invalid parameter schema.';
    }
    final isRuntime =
        request.operation == DesktopHelperOperation.runtimeStart ||
            request.operation == DesktopHelperOperation.runtimeStop;
    if (isRuntime != (request.runtimeArtifact != null)) {
      return 'Desktop helper runtime operation has an invalid artifact.';
    }
    if (request.runtimeArtifact != null &&
        !_runtimeArtifacts.contains(request.runtimeArtifact)) {
      return 'Desktop helper runtime artifact is not bundled.';
    }
    if (!_validateOperation(request.operation, request.parameters)) {
      return 'Desktop helper request has invalid parameter values.';
    }
    return null;
  }

  static bool _looksExecutable(String key) {
    final normalized = key.toLowerCase();
    return normalized.contains('path') ||
        normalized.contains('command') ||
        normalized.contains('argument') ||
        normalized.contains('environment') ||
        normalized.contains('shell');
  }

  static bool _validateOperation(
    DesktopHelperOperation operation,
    Map<String, Object?> parameters,
  ) =>
      switch (operation) {
        DesktopHelperOperation.tunOpen =>
          _interface(parameters['interface']) && _mtu(parameters['mtu']),
        DesktopHelperOperation.tunClose => _interface(parameters['interface']),
        DesktopHelperOperation.routeApply =>
          _interface(parameters['interface']) && _routes(parameters['routes']),
        DesktopHelperOperation.routeRollback =>
          _transaction(parameters['transaction']),
        DesktopHelperOperation.dnsApply =>
          _interface(parameters['interface']) &&
              _servers(parameters['servers']),
        DesktopHelperOperation.dnsRollback =>
          _transaction(parameters['transaction']),
        DesktopHelperOperation.runtimeStart ||
        DesktopHelperOperation.runtimeStop =>
          _runtimeToken(parameters['runtimeToken']),
      };

  static bool _interface(Object? value) =>
      value is String &&
      RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,63}$').hasMatch(value);

  static bool _mtu(Object? value) =>
      value is int && value >= 576 && value <= 65535;

  static bool _routes(Object? value) =>
      value is List &&
      value.isNotEmpty &&
      value.length <= 128 &&
      value.every((item) => item is String && _cidr(item));

  static bool _servers(Object? value) =>
      value is List &&
      value.isNotEmpty &&
      value.length <= 16 &&
      value.every(
          (item) => item is String && InternetAddress.tryParse(item) != null);

  static bool _transaction(Object? value) =>
      value is String && RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(value);

  static bool _runtimeToken(Object? value) =>
      value is String && RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(value);

  static bool _cidr(String value) {
    final parts = value.split('/');
    if (parts.length != 2) return false;
    final address = InternetAddress.tryParse(parts.first);
    final prefix = int.tryParse(parts.last);
    if (address == null || prefix == null) return false;
    final maximum = address.type == InternetAddressType.IPv4 ? 32 : 128;
    return prefix >= 0 && prefix <= maximum;
  }
}

abstract interface class DesktopHelperTransport {
  Future<DesktopHelperResponse> send(DesktopHelperRequest request);
}

class UnavailableDesktopHelperTransport implements DesktopHelperTransport {
  const UnavailableDesktopHelperTransport();

  @override
  Future<DesktopHelperResponse> send(DesktopHelperRequest request) async =>
      const DesktopHelperResponse(
        state: DesktopHelperState.unavailable,
        message: 'Desktop privileged helper is unavailable.',
      );
}

class DesktopHelperClient {
  DesktopHelperClient({
    DesktopHelperTransport transport =
        const UnavailableDesktopHelperTransport(),
    this.timeout = const Duration(seconds: 10),
  }) : _transport = transport;

  final DesktopHelperTransport _transport;
  final Duration timeout;
  DesktopHelperState _state = DesktopHelperState.unavailable;

  DesktopHelperState get state => _state;

  Future<DesktopHelperResponse> execute(
    DesktopHelperRequest request, {
    DesktopHelperRequest? rollback,
  }) async {
    final validation = DesktopHelperProtocol.validate(request);
    if (validation != null) {
      _state = DesktopHelperState.failed;
      return DesktopHelperResponse(state: _state, message: validation);
    }
    _state = DesktopHelperState.applying;
    try {
      final response = await _transport.send(request).timeout(timeout);
      _state = response.state;
      if (response.isSuccess || rollback == null) return response;
      return _rollback(rollback, response.message);
    } on TimeoutException {
      _state = DesktopHelperState.failed;
      if (rollback != null) return _rollback(rollback, 'Helper timed out.');
      return DesktopHelperResponse(state: _state, message: 'Helper timed out.');
    } catch (error) {
      _state = DesktopHelperState.failed;
      if (rollback != null) return _rollback(rollback, '$error');
      return DesktopHelperResponse(state: _state, message: '$error');
    }
  }

  Future<DesktopHelperResponse> _rollback(
    DesktopHelperRequest request,
    String originalMessage,
  ) async {
    final validation = DesktopHelperProtocol.validate(request);
    if (validation != null) {
      _state = DesktopHelperState.failed;
      return DesktopHelperResponse(
        state: _state,
        message: '$originalMessage Rollback rejected: $validation',
      );
    }
    _state = DesktopHelperState.rollingBack;
    try {
      final response = await _transport.send(request).timeout(timeout);
      _state = response.isSuccess ? DesktopHelperState.failed : response.state;
      return DesktopHelperResponse(
        state: _state,
        message: response.isSuccess
            ? originalMessage
            : '$originalMessage Rollback failed: ${response.message}',
      );
    } catch (error) {
      _state = DesktopHelperState.failed;
      return DesktopHelperResponse(
        state: _state,
        message: '$originalMessage Rollback failed: $error',
      );
    }
  }
}
