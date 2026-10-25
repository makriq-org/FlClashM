import 'dart:convert';
import 'dart:typed_data';

import 'package:flclashx/product/backend/backend_client.dart';
import 'package:flclashx/product/backend/resource_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _ResourceHost {
  final requests = <Map<String, dynamic>>[];
  Uint8List bytes = Uint8List.fromList(utf8.encode('DOMAIN,example.org\n'));
  Map<String, dynamic> inspection = {
    'format': 'text',
    'size': 19,
    'editable': true,
  };
  final failures = <String, String>{};
  Object? exportSize;
  bool pendingExport = false;
  bool emptyChunk = false;

  late final client = BackendClient(
    transport: call,
    events: const Stream.empty(),
  );
  late final resources = BackendResourceClient(client);

  List<Map<String, dynamic>> calls(String method) =>
      requests.where((request) => request['method'] == method).toList();

  Map<String, dynamic> params(String method) =>
      calls(method).single['params'] as Map<String, dynamic>;

  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async {
    requests.add(request);
    final method = request['method'] as String;
    if (failures[method] case final failure?) {
      return {
        'apiVersion': 1,
        'error': {'code': failure, 'message': '$method failed'},
      };
    }
    final params = request['params'] as Map? ?? {};
    final receipt = {
      'status': 'succeeded',
      'blob': {'token': 'resource-token', 'size': exportSize ?? bytes.length},
    };
    final Object? result;
    switch (method) {
      case 'provider.inspect':
        result = inspection;
      case 'provider.export':
      case 'authoring.resource.export':
        result = pendingExport ? {'status': 'accepted'} : receipt;
      case 'operation.get':
        result = receipt;
      case 'authoring.resource.update':
        result = {'status': 'succeeded'};
      case 'blob.read':
        final offset = params['offset'] as int;
        final limit = params['limit'] as int;
        result = {
          'data': base64Encode(
            emptyChunk ? [] : bytes.skip(offset).take(limit).toList(),
          ),
        };
      case 'blob.delete':
        result = true;
      case 'snapshot':
      case 'runtime.view':
        result = <String, dynamic>{};
      default:
        throw StateError('Unexpected resource request: $method');
    }
    return {'apiVersion': 1, 'result': result};
  }
}

Matcher _backendError(String code) => isA<BackendException>().having(
  (error) => error.code,
  'backend error code',
  code,
);

void main() {
  for (final (externalType, type) in [('Proxy', 'proxy'), ('Rule', 'rule')]) {
    test(
      'inspect normalizes $externalType and preserves the engine name',
      () async {
        final host = _ResourceHost();
        final inspection = await host.resources.inspectProvider(
          name: 'Provider / Узлы',
          type: externalType,
        );
        expect(inspection.format, ResourceFormat.text);
        expect(inspection.editable, isTrue);
        expect(inspection.size, 19);
        expect(host.params('provider.inspect'), {
          'name': 'Provider / Узлы',
          'type': type,
        });
        expect(host.requests, hasLength(1));
      },
    );
  }

  for (final format in [ResourceFormat.mrs, ResourceFormat.binary]) {
    test('inspect preserves ${format.name} as read only', () async {
      final host = _ResourceHost()
        ..inspection = {'format': format.name, 'size': 20, 'editable': false};
      final inspection = await host.resources.inspectProvider(
        name: 'rules',
        type: 'Rule',
      );
      expect(inspection.format, format);
      expect(inspection.editable, isFalse);
    });
  }

  test('inspect exposes backend resource failures', () async {
    final host = _ResourceHost()
      ..failures['provider.inspect'] = 'resource_unavailable';
    await expectLater(
      host.resources.inspectProvider(name: 'rules', type: 'Rule'),
      throwsA(_backendError('resource_unavailable')),
    );
    expect(host.requests, hasLength(1));
  });

  for (final invalid in [
    {'format': 'unknown', 'size': 1, 'editable': false},
    {'format': 'text', 'size': -1, 'editable': true},
    {'format': 'text', 'size': 1.5, 'editable': true},
    {'format': 'text', 'size': 1},
  ]) {
    test(
      'invalid inspection fails instead of becoming binary: $invalid',
      () async {
        final host = _ResourceHost()..inspection = invalid;
        await expectLater(
          host.resources.inspectProvider(name: 'rules', type: 'Rule'),
          throwsA(_backendError(BackendException.failed)),
        );
      },
    );
  }

  test(
    'MRS preview requests backend text and releases its export blob',
    () async {
      final host = _ResourceHost()..pendingExport = true;
      expect(
        await host.resources.readProviderText(name: 'Rules / 1', type: 'Rule'),
        'DOMAIN,example.org\n',
      );
      expect(host.params('provider.export'), {
        'name': 'Rules / 1',
        'type': 'rule',
        'asText': true,
      });
      expect(host.calls('operation.get'), hasLength(1));
      expect(host.params('blob.delete'), {'token': 'resource-token'});
      expect(host.requests.last['method'], 'blob.delete');
    },
  );

  test('binary export downloads bounded chunks and deletes the blob', () async {
    final host = _ResourceHost()
      ..bytes = Uint8List.fromList(
        List.generate(600000, (index) => index % 256),
      );
    expect(
      await host.resources.exportProvider(name: 'Nodes', type: 'Proxy'),
      host.bytes,
    );
    expect(host.params('provider.export'), {
      'name': 'Nodes',
      'type': 'proxy',
      'asText': false,
    });
    expect(host.calls('blob.read'), hasLength(4));
    expect(host.calls('blob.delete'), hasLength(1));
  });

  for (final collection in AuthoringResourceCollection.values) {
    test('${collection.name} export uses only collection and id', () async {
      final host = _ResourceHost();
      expect(
        await host.resources.exportAuthoringResource(
          collection: collection,
          id: 42,
        ),
        host.bytes,
      );
      expect(host.params('authoring.resource.export'), {
        'collection': collection.name,
        'id': 42,
        'asText': false,
      });
      expect(host.calls('authoring.resource.update'), isEmpty);
      expect(host.calls('blob.delete'), hasLength(1));
    });
  }

  test(
    'explicit uncached remote preview refreshes in Go before text export',
    () async {
      final host = _ResourceHost();
      expect(
        await host.resources.readAuthoringText(
          collection: AuthoringResourceCollection.clashProviders,
          id: 42,
          refresh: true,
        ),
        'DOMAIN,example.org\n',
      );
      expect(host.params('authoring.resource.update'), {
        'collection': 'clashProviders',
        'id': 42,
      });
      expect(host.params('authoring.resource.export'), {
        'collection': 'clashProviders',
        'id': 42,
        'asText': true,
      });
      final methods = host.requests
          .map((request) => request['method'])
          .toList();
      expect(
        methods.indexOf('authoring.resource.update'),
        lessThan(methods.indexOf('authoring.resource.export')),
      );
    },
  );

  test('failed remote refresh does not export stale content', () async {
    final host = _ResourceHost()
      ..failures['authoring.resource.update'] = 'download_failed';
    await expectLater(
      host.resources.readAuthoringText(
        collection: AuthoringResourceCollection.clashProviders,
        id: 42,
        refresh: true,
      ),
      throwsA(_backendError('download_failed')),
    );
    expect(host.calls('authoring.resource.export'), isEmpty);
    expect(host.calls('blob.read'), isEmpty);
  });

  test('failed export preserves its error without reading a blob', () async {
    final host = _ResourceHost()..failures['provider.export'] = 'dump_failed';
    await expectLater(
      host.resources.readProviderText(name: 'rules', type: 'Rule'),
      throwsA(_backendError('dump_failed')),
    );
    expect(host.calls('blob.read'), isEmpty);
    expect(host.calls('blob.delete'), isEmpty);
  });

  for (final cleanupFails in [false, true]) {
    test('read error survives cleanup, cleanup fails: $cleanupFails', () async {
      final host = _ResourceHost()..failures['blob.read'] = 'read_failed';
      if (cleanupFails) host.failures['blob.delete'] = 'cleanup_failed';
      await expectLater(
        host.resources.readProviderText(name: 'rules', type: 'Rule'),
        throwsA(_backendError('read_failed')),
      );
      expect(host.params('blob.delete'), {'token': 'resource-token'});
    });
  }

  test('invalid UTF8 is rejected after releasing the blob', () async {
    final host = _ResourceHost()..bytes = Uint8List.fromList([0xff]);
    await expectLater(
      host.resources.readProviderText(name: 'rules', type: 'Rule'),
      throwsA(isA<FormatException>()),
    );
    expect(host.calls('blob.delete'), hasLength(1));
  });

  test('truncated download is rejected and its blob is released', () async {
    final host = _ResourceHost()..emptyChunk = true;
    await expectLater(
      host.resources.exportProvider(name: 'rules', type: 'Rule'),
      throwsA(_backendError(BackendException.failed)),
    );
    expect(host.calls('blob.delete'), hasLength(1));
  });

  for (final size in [-1, '19']) {
    test('invalid blob size $size still releases its token', () async {
      final host = _ResourceHost()..exportSize = size;
      await expectLater(
        host.resources.exportProvider(name: 'rules', type: 'Rule'),
        throwsA(_backendError(BackendException.failed)),
      );
      expect(host.calls('blob.read'), isEmpty);
      expect(host.calls('blob.delete'), hasLength(1));
    });
  }

  test('empty resource releases its blob without read requests', () async {
    final host = _ResourceHost()..bytes = Uint8List(0);
    expect(
      await host.resources.readProviderText(name: 'rules', type: 'Rule'),
      isEmpty,
    );
    expect(host.calls('blob.read'), isEmpty);
    expect(host.calls('blob.delete'), hasLength(1));
  });

  test('cleanup failure preserves a successfully exported resource', () async {
    final host = _ResourceHost()..failures['blob.delete'] = 'cleanup_failed';
    expect(await host.resources.exportProvider(name: 'rules', type: 'Rule'), host.bytes);
    expect(host.calls('blob.delete'), hasLength(1));
  });

  test(
    'post-export snapshot failure still releases the committed blob',
    () async {
      final host = _ResourceHost()
        ..failures['snapshot'] = 'refresh_failed'
        ..failures['blob.delete'] = 'cleanup_failed';
      await expectLater(
        host.resources.exportProvider(name: 'rules', type: 'Rule'),
        throwsA(
          isA<BackendCommittedException>().having(
            (error) => error.code,
            'original refresh failure',
            'refresh_failed',
          ),
        ),
      );
      expect(host.calls('blob.read'), isEmpty);
      expect(host.params('blob.delete'), {'token': 'resource-token'});
    },
  );

  test('unknown runtime provider type is rejected before IPC', () async {
    final host = _ResourceHost();
    await expectLater(
      host.resources.inspectProvider(name: 'rules', type: 'Other'),
      throwsArgumentError,
    );
    expect(host.requests, isEmpty);
  });
}
