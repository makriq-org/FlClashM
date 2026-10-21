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
  Map<String, dynamic> extraSettings = {};
  Map<String, dynamic> profileMetadata = {};
  Map<String, dynamic> view = {
    'config': {'mode': 'rule'},
  };
  Map<String, dynamic> get runtime => {
    'instanceId': instance,
    'appliedGeneration': generation,
    'desiredRunning': running,
    'appliedRunning': running,
    'observed': {'state': running ? 'running' : 'stopped'},
  };
  Map<String, dynamic> get snapshot => {
    'apiVersion': 1,
    'seq': sequence,
    'runtime': runtime,
    'catalog': {
      'revision': revision,
      'settings': {
        'unknown': 9007199254740993,
        'currentProfileId': 'one',
        ...extraSettings,
      },
      'profiles': [
        {
          'metadata': {'id': 'one', 'label': 'Original', ...profileMetadata},
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
        result = view;
      case 'runtime.start':
      case 'runtime.stop':
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
    'failed selection refreshes the rolled back view without an event',
    () async {
      final host = ClientHost();
      final client = BackendClient(
        transport: (request) async {
          if (request['method'] == 'proxy.select') {
            host
              ..profileMetadata = {
                'selectedMap': {'GLOBAL': 'Unavailable'},
              }
              ..view = {
                'profileId': 'one',
                'selected-map': {'GLOBAL': 'Working'},
              }
              ..operations['runtime-selection'] = {
                'status': 'failed',
                'error': 'operation failed',
              };
            return {
              'apiVersion': 1,
              'result': {
                'status': 'succeeded',
                'runtimeOperationId': 'runtime-selection',
              },
            };
          }
          return host.call(request);
        },
        events: host.events.stream,
      );
      await client.attach();
      await expectLater(
        client.command('proxy.select', {
          'group': 'GLOBAL',
          'proxy': 'Unavailable',
        }),
        throwsStateError,
      );
      final profiles = client.settings['profiles'] as List;
      expect((profiles.single as Map)['selectedMap'], {'GLOBAL': 'Working'});
      final catalog = client.snapshot['catalog'] as Map;
      final persisted =
          ((catalog['profiles'] as List).single as Map)['metadata'] as Map;
      expect(persisted['selectedMap'], {'GLOBAL': 'Unavailable'});
      await client.detach();
      await host.close();
    },
  );

  test(
    'applied selections are scoped to their running profile and preserve reset',
    () async {
      final host = ClientHost()
        ..profileMetadata = {
          'selectedMap': {'GLOBAL': 'Desired'},
        }
        ..view = {'profileId': 'one', 'selected-map': <String, dynamic>{}};
      final client = BackendClient(
        transport: host.call,
        events: host.events.stream,
      );
      await client.attach();
      Map selection() =>
          ((client.settings['profiles'] as List).single as Map)['selectedMap']
              as Map;
      expect(selection(), isEmpty);
      host.view['profileId'] = 'another-profile';
      await client.refresh();
      expect(selection(), {'GLOBAL': 'Desired'});
      host.view['profileId'] = 'one';
      host.running = false;
      await client.refresh();
      expect(selection(), {'GLOBAL': 'Desired'});
      await client.detach();
      await host.close();
    },
  );

  test('refresh failure preserves the original command error', () async {
    final host = ClientHost();
    final client = BackendClient(
      transport: (request) async {
        throw StateError(
          request['method'] == 'proxy.select'
              ? 'selection failed'
              : 'refresh failed',
        );
      },
      events: host.events.stream,
    );
    await expectLater(
      client.command('proxy.select', {
        'group': 'GLOBAL',
        'proxy': 'Unavailable',
      }),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'selection failed',
        ),
      ),
    );
    await host.close();
  });

  test('repeated Start shares one operation while Stop remains immediate', () async {
    final host = ClientHost();
    final gate = Completer<void>();
    var starts = 0;
    final client = BackendClient(
      transport: (request) async {
        if (request['method'] == 'runtime.start') {
          starts++;
          await gate.future;
        }
        return host.call(request);
      },
      events: host.events.stream,
    );
    final start = client.command('runtime.start');
    expect(identical(start, client.command('runtime.start')), isTrue);
    expect(starts, 1);
    await client.command('runtime.stop');
    expect(host.requests.where((r) => r['method'] == 'runtime.stop'), hasLength(1));
    // A deliberate Start after Stop is a new intent, even while the old Start waits.
    final again = client.command('runtime.start');
    expect(starts, 2);
    gate.complete();
    await Future.wait([start, again]);
    await client.command('runtime.start');
    expect(starts, 3);
    await host.close();
  });

  test('custom controller endpoints project their enabled state without changing backend data', () async {
    final host = ClientHost()
      ..extraSettings = {
        'patchClashConfig': {'external-controller': '127.0.0.1:17892'},
      };
    final client = BackendClient(
      transport: host.call,
      events: host.events.stream,
    );
    await client.attach();
    expect(
      (client.settings['patchClashConfig'] as Map)['external-controller'],
      '127.0.0.1:9090',
    );
    final settings = (client.snapshot['catalog'] as Map)['settings'] as Map;
    expect(
      (settings['patchClashConfig'] as Map)['external-controller'],
      '127.0.0.1:17892',
    );
    await client.detach();
    await host.close();
  });
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
