import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flclashx/product/backend/backend_client.dart';
import 'package:flutter_test/flutter_test.dart';

class ClientHost {
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final requests = <Map<String, dynamic>>[];
  String instance = 'service-1';
  int sequence = 1;
  int generation = 1;
  int revision = 1;
  bool running = true;
  final blobs = <int>[];
  final operations = <String, Map<String, dynamic>>{};
  Map<String, dynamic> get runtime => {
    'instanceId': instance,
    'appliedGeneration': generation,
    'desiredRunning': running,
    'observed': {'state': running ? 'running' : 'stopped'},
  };
  Map<String, dynamic> get snapshot => {
    'apiVersion': 1,
    'seq': sequence,
    'runtime': runtime,
    'catalog': {
      'revision': revision,
      'settings': {'unknown': 9007199254740993, 'currentProfileId': 'one'},
      'profiles': [
        {
          'metadata': {'id': 'one', 'label': 'Original'},
          'revision': revision,
        },
      ],
    },
  };
  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async {
    requests.add(request);
    dynamic result;
    final params = request['params'] as Map? ?? {};
    switch (request['method']) {
      case 'snapshot':
        result = snapshot;
      case 'runtime.view':
        result = {
          'config': {'mode': 'rule'},
        };
      case 'runtime.start':
        result = {'operationId': request['operationId'], 'status': 'accepted'};
        operations[request['operationId'] as String] = {
          'operationId': request['operationId'],
          'status': 'succeeded',
        };
      case 'operation.get':
        result = operations[params['operationId']];
      case 'operation.cancel':
        result = true;
      case 'blob.create':
        result = {'token': 'private-token', 'size': 0};
      case 'blob.append':
        expect(params['offset'], blobs.length);
        blobs.addAll(base64Decode(params['data'] as String));
        result = {'token': 'private-token', 'size': blobs.length};
      case 'blob.read':
        final offset = params['offset'] as int;
        final limit = params['limit'] as int;
        result = {
          'data': base64Encode(blobs.skip(offset).take(limit).toList()),
        };
      default:
        throw StateError('Unexpected UI command: ${request['method']}');
    }
    return {
      'apiVersion': 1,
      'operationId': request['operationId'],
      'result': result,
    };
  }

  Future<void> close() => events.close();
}

void main() {
  test(
    'snapshot and events reject stale state and resync after process replacement',
    () async {
      final host = ClientHost();
      final client = BackendClient(
        transport: host.call,
        events: host.events.stream,
      );
      await client.attach();
      host
        ..sequence = 4
        ..running = false
        ..events.add({
          'apiVersion': 1,
          'seq': 4,
          'runtime': host.runtime,
          'catalogRevision': 1,
        });
      expect((client.snapshot['runtime'] as Map)['desiredRunning'], false);
      host.events.add({
        'apiVersion': 1,
        'seq': 2,
        'runtime': {...host.runtime, 'desiredRunning': true},
        'catalogRevision': 1,
      });
      expect((client.snapshot['runtime'] as Map)['desiredRunning'], false);
      host
        ..instance = 'service-2'
        ..sequence = 1
        ..running = true
        ..events.add({
          'apiVersion': 1,
          'seq': 1,
          'runtime': host.runtime,
          'catalogRevision': 1,
        });
      await client.refresh();
      expect((client.snapshot['runtime'] as Map)['instanceId'], 'service-2');
      host.events.add({
        'apiVersion': 1,
        'seq': 100,
        'runtime': {'instanceId': 'service-1', 'desiredRunning': false},
      });
      await client.refresh();
      expect((client.snapshot['runtime'] as Map)['instanceId'], 'service-2');
      expect((client.snapshot['runtime'] as Map)['desiredRunning'], true);
      await client.detach();
      await host.close();
    },
  );

  test(
    'detaching UI never submits runtime teardown and copied projections preserve unknown settings',
    () async {
      final host = ClientHost();
      final client = BackendClient(
        transport: host.call,
        events: host.events.stream,
      );
      await client.attach();
      final settings = client.settings;
      expect(settings['unknown'], 9007199254740993);
      (settings['profiles'] as List).clear();
      expect(client.settings['profiles'], hasLength(1));
      expect(client.profileRevision('one'), 1);
      await client.detach();
      expect(
        host.requests.map((r) => r['method']),
        isNot(contains('runtime.stop')),
      );
      expect(host.running, true);
      await host.close();
    },
  );

  test(
    'commands retain operation identity and cancellation is explicit',
    () async {
      final host = ClientHost();
      final client = BackendClient(
        transport: host.call,
        events: host.events.stream,
      );
      await client.command('runtime.start', {}, 'user-operation');
      expect(host.requests.first['operationId'], 'user-operation');
      expect(
        host.requests.where((r) => r['method'] == 'operation.cancel'),
        isEmpty,
      );
      expect(await client.cancel('other-operation'), true);
      expect(
        (host.requests.last['params'] as Map)['operationId'],
        'other-operation',
      );
      await host.close();
    },
  );

  test(
    'large profile and backup transfers cross Binder in bounded chunks',
    () async {
      final host = ClientHost();
      final client = BackendClient(
        transport: host.call,
        events: host.events.stream,
      );
      final bytes = Uint8List.fromList(
        List.generate(600000, (index) => index % 256),
      );
      final token = await client.upload(bytes);
      expect(await client.download(token, bytes.length), bytes);
      expect(
        host.requests.where((r) => r['method'] == 'blob.append'),
        hasLength(4),
      );
      for (final request in host.requests.where(
        (r) => r['method'] == 'blob.append',
      )) {
        expect(jsonEncode(request).length, lessThan(300000));
      }
      await host.close();
    },
  );
}
