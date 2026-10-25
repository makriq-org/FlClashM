import 'dart:async';
import 'dart:io';
import 'dart:convert';

import '../clash/lib.dart';
import '../product/backend/backend.dart';
import 'desktop/model.dart';
import 'interface.dart';
import 'method.dart';

/// Thin compatibility transport for upstream read-only UI helpers.
/// Runtime and persistence mutations exclusively use Go API v1.
class CoreLib extends CoreHandlerInterface {
  int _revision = 0;
  @override
  Future<CoreLifecycleResult> start() async {
    await backendClient.attach();
    return CoreLifecycleResult(
      revision: ++_revision,
      outcome: CoreLifecycleOutcome.applied,
    );
  }

  @override
  Future<CoreLifecycleResult> restart() async {
    await backendClient.command('runtime.restart');
    return CoreLifecycleResult(
      revision: ++_revision,
      outcome: CoreLifecycleOutcome.applied,
    );
  }

  @override
  Future<CoreLifecycleResult> stop() async {
    await backendClient.command('runtime.stop');
    return CoreLifecycleResult(
      revision: ++_revision,
      outcome: CoreLifecycleOutcome.applied,
    );
  }

  @override
  Future<CoreLifecycleResult> close() async {
    await backendClient.detach();
    await clashLib?.destroy();
    return CoreLifecycleResult(
      revision: ++_revision,
      outcome: CoreLifecycleOutcome.applied,
    );
  }

  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) async {
    if (const {
      CoreMethod.setupConfig,
      CoreMethod.updateConfig,
      CoreMethod.initClash,
      CoreMethod.shutdown,
      CoreMethod.startListener,
      CoreMethod.stopListener,
      CoreMethod.buildProfile,
    }.contains(method)) {
      throw StateError(
        'Runtime configuration belongs to Go API v1: ${method.name}',
      );
    }
    dynamic result;
    if (method == CoreMethod.getIsInit) {
      result = backendClient.attached;
    } else if (method == CoreMethod.changeProxy) {
      final data = Map<String, dynamic>.from(arguments as Map);
      await backendClient.command('proxy.select', {
        'group': data['group-name'],
        'proxy': data['proxy-name'],
      });
      result = {'changed': true};
    } else if (const {
      CoreMethod.closeConnection,
      CoreMethod.closeConnections,
      CoreMethod.resetConnections,
      CoreMethod.updateExternalProvider,
      CoreMethod.sideLoadExternalProvider,
      CoreMethod.updateGeoData,
    }.contains(method)) {
      final (name, params) = switch (method) {
        CoreMethod.closeConnection => (
          'connection.close',
          <String, dynamic>{'id': arguments},
        ),
        CoreMethod.closeConnections => (
          'connections.close',
          <String, dynamic>{},
        ),
        CoreMethod.resetConnections => (
          'connections.reset',
          <String, dynamic>{},
        ),
        CoreMethod.updateExternalProvider => (
          'provider.refresh',
          <String, dynamic>{'name': arguments},
        ),
        CoreMethod.sideLoadExternalProvider => (
          'provider.sideload',
          <String, dynamic>{
            'name': (arguments as Map)['providerName'],
            'data': arguments['data'],
          },
        ),
        CoreMethod.updateGeoData => (
          'geo.update',
          <String, dynamic>{
            'geo-type': switch (arguments) {
              'GEOIP' => 'GeoIp',
              'GEOSITE' => 'GeoSite',
              _ => arguments,
            },
          },
        ),
        _ => throw StateError('Unsupported engine command'),
      };
      await backendClient.command('engine.command', {
        'method': name,
        'params': params,
      });
      result =
          (method == CoreMethod.updateExternalProvider ||
              method == CoreMethod.sideLoadExternalProvider ||
              method == CoreMethod.updateGeoData)
          ? ''
          : true;
    } else {
      result = await clashLib!
          .invokeAction(method.name, arguments)
          .timeout(timeout ?? const Duration(seconds: 60));
      if (result is String && T != String) {
        // Legacy engine helpers sometimes wrap JSON in a string.
        result = decodeLegacyResult(result);
      }
      result = normalizeLegacyJson(result);
      if (method == CoreMethod.getProxies &&
          result is Map &&
          !result.containsKey('proxies')) {
        result = {'proxies': result, 'all': result.keys.toList()};
      }
      if (method == CoreMethod.getConnections && result is Map)
        result = result['connections'];
    }
    return result as T?;
  }
}

final _lib = CoreLib();
CoreLib? get coreLib => Platform.isAndroid ? _lib : null;

dynamic decodeLegacyResult(String value) =>
    value.isEmpty ? null : jsonDecode(value);

/// MethodChannel maps have dynamic keys; generated JSON models require strings
/// at every level, including empty maps inside a snapshot.
dynamic normalizeLegacyJson(Object? value) => switch (value) {
  Map value => value.map<String, dynamic>(
    (key, value) => MapEntry(key as String, normalizeLegacyJson(value)),
  ),
  List value => value.map(normalizeLegacyJson).toList(),
  _ => value,
};
