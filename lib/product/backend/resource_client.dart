import 'dart:convert';
import 'dart:typed_data';

import 'backend_client.dart';

enum ResourceFormat { text, mrs, binary }

enum AuthoringResourceCollection { clashProviders, scripts, iconSets }

class ProviderInspection {
  const ProviderInspection({
    required this.format,
    required this.size,
    required this.editable,
  });

  final ResourceFormat format;
  final int size;
  final bool editable;
}

/// Transfers resources by backend identity. Engine paths never cross this API.
class BackendResourceClient {
  const BackendResourceClient(this.client);

  final BackendClient client;

  Map<String, dynamic> _provider(String name, String type) => {
    'name': name,
    'type': switch (type.toLowerCase()) {
      'proxy' => 'proxy',
      'rule' => 'rule',
      _ => throw ArgumentError.value(type, 'type', 'Unknown provider type'),
    },
  };

  Future<ProviderInspection> inspectProvider({
    required String name,
    required String type,
  }) async {
    final result = await client.request(
      'provider.inspect',
      _provider(name, type),
    );
    if (result is! Map) throw _invalidInspection;
    final format = switch (result['format']) {
      'text' => ResourceFormat.text,
      'mrs' => ResourceFormat.mrs,
      'binary' => ResourceFormat.binary,
      _ => throw _invalidInspection,
    };
    final size = result['size'];
    final editable = result['editable'];
    if (size is! int || size < 0 || editable is! bool) {
      throw _invalidInspection;
    }
    return ProviderInspection(format: format, size: size, editable: editable);
  }

  Future<Uint8List> exportProvider({
    required String name,
    required String type,
    bool asText = false,
  }) =>
      _export('provider.export', {..._provider(name, type), 'asText': asText});

  Future<String> readProviderText({
    required String name,
    required String type,
  }) async =>
      utf8.decode(await exportProvider(name: name, type: type, asText: true));

  /// Refresh is requested only by an explicit preview of an uncached remote
  /// resource. Go owns the download, validation and cache.
  Future<Uint8List> exportAuthoringResource({
    required AuthoringResourceCollection collection,
    required int id,
    bool asText = false,
    bool refresh = false,
  }) async {
    final identity = {'collection': collection.name, 'id': id};
    if (refresh) {
      await client.command('authoring.resource.update', identity);
    }
    return _export('authoring.resource.export', {
      ...identity,
      'asText': asText,
    });
  }

  Future<String> readAuthoringText({
    required AuthoringResourceCollection collection,
    required int id,
    bool refresh = false,
  }) async => utf8.decode(
    await exportAuthoringResource(
      collection: collection,
      id: id,
      asText: true,
      refresh: refresh,
    ),
  );

  static const _invalidInspection = BackendException(
    BackendException.failed,
    'Invalid backend resource inspection',
  );
  static const _invalidExport = BackendException(
    BackendException.failed,
    'Invalid backend resource export',
  );

  Future<Uint8List> _export(String method, Map<String, dynamic> params) async {
    final Map<String, dynamic> receipt;
    try {
      receipt = await client.command(method, params);
    } on BackendCommittedException catch (error) {
      // Export succeeded, but command's subsequent snapshot refresh failed.
      // Its receipt still owns a blob which must be released.
      final blob = error.receipt['blob'];
      if (blob is Map && blob['token'] is String) {
        await client.discardBlob(blob['token'] as String);
      }
      rethrow;
    }
    final blob = receipt['blob'];
    if (blob is! Map || blob['token'] is! String || blob['token'] == '') {
      throw _invalidExport;
    }
    final token = blob['token'] as String;
    try {
      final size = blob['size'];
      if (size is! int || size < 0) throw _invalidExport;
      return await client.download(token, size);
    } finally {
      await client.discardBlob(token);
    }
  }
}
