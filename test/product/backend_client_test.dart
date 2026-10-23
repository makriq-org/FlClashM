import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flclashx/product/backend/backend_client.dart';
import 'package:flclashx/product/backend/backend_errors.dart';
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
  for (final method in ['profile.put', 'profile.import.file']) {
    for (final concurrent in [false, true]) {
      test(
        '$method keeps committed revision after apply failure, concurrent=$concurrent',
        () async {
          final host = ClientHost();
          var first = true;
          final client = BackendClient(
            transport: (request) async {
              if (request['method'] == 'blob.create') host.blobs.clear();
              if (request['method'] == method) {
                final params = request['params'] as Map;
                if (params['expectedRevision'] != host.revision) {
                  return {
                    'apiVersion': 1,
                    'error': {
                      'code': 'conflict',
                      'message': 'profile revision changed',
                    },
                  };
                }
                final savedRevision = ++host.revision;
                final apply = first;
                first = false;
                if (apply) {
                  host.operations['saved-apply'] = {
                    'status': 'failed',
                    'errorCode': 'failed',
                    'error': 'node did not start',
                  };
                }
                return {
                  'apiVersion': 1,
                  'result': {
                    'status': 'succeeded',
                    'profileId': 'one',
                    'revision': savedRevision,
                    if (apply) 'runtimeOperationId': 'saved-apply',
                  },
                };
              }
              if (request['method'] == 'operation.get' && concurrent) {
                host.revision = 3;
              }
              return host.call(request);
            },
            events: host.events.stream,
          );
          await client.attach();
          var expectedRevision = client.profileRevision('one');
          Future<Map<String, dynamic>> save() => method == 'profile.put'
              ? client.command(method, {
                  'metadata': {'id': 'one'},
                  'expectedRevision': expectedRevision,
                })
              : client.saveSource(
                  {'id': 'one'},
                  Uint8List.fromList([1]),
                  expectedRevision: expectedRevision,
                );
          try {
            await save();
            fail('runtime failure was hidden');
          } on BackendCommittedException catch (error) {
            expect(error.revisionFor('one'), 2);
            expect(error.revisionFor('another'), isNull);
            expectedRevision = error.revisionFor('one')!;
          }
          expect(client.profileRevision('one'), concurrent ? 3 : 2);
          if (concurrent) {
            await expectLater(
              save(),
              throwsA(
                isA<BackendException>().having(
                  (error) => error.isRevisionConflict,
                  'CAS conflict',
                  true,
                ),
              ),
            );
          } else {
            expect((await save())['revision'], 3);
          }
          await client.detach();
          await host.close();
        },
      );
    }
  }

  test(
    'replacement and rebind restore UI preparation with fresh receipts',
    () async {
      final host = ClientHost()..running = false;
      final reconnects = StreamController<void>.broadcast();
      final sessions = <Map<String, dynamic>>[];
      var prepared = false;
      final client = BackendClient(
        transport: (request) async {
          if (request['method'] == 'ui.attach') {
            sessions.add(request);
            final id = request['operationId'] as String;
            final receipt = host.operations.putIfAbsent(id, () {
              prepared = true;
              return {'status': 'succeeded', 'operationId': id};
            });
            return {'apiVersion': 1, 'result': receipt};
          }
          return host.call(request);
        },
        events: host.events.stream,
        reconnects: reconnects.stream,
      );
      await client.attach();
      await client.openUI();
      for (final instance in ['service-2', 'service-2']) {
        host.instance = instance;
        prepared = false;
        final resynced = client.changes.first;
        reconnects.add(null);
        await resynced;
        expect(prepared, true);
        expect((sessions.last['params'] as Map)['restore'], true);
        expect((client.snapshot['runtime'] as Map)['desiredRunning'], false);
      }
      expect(
        sessions.map((request) => request['operationId']).toSet(),
        hasLength(3),
      );
      await client.detach();
      await reconnects.close();
      await host.close();
    },
  );
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
        throwsA(isA<BackendException>()),
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
        isA<BackendException>()
            .having((e) => e.code, 'code', BackendException.unavailable)
            .having((e) => e.message, 'message', 'selection failed'),
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

  test('a saved change keeps its receipt when its runtime apply is superseded', () async {
    final host = ClientHost()
      ..operations['runtime-apply'] = {
        'status': 'failed',
        'errorCode': 'superseded',
        'error': 'operation superseded',
      };
    final client = BackendClient(
      transport: (request) async {
        if (request['method'] == 'profile.put') {
          return {
            'apiVersion': 1,
            'result': {
              'status': 'succeeded',
              'revision': 2,
              'runtimeOperationId': 'runtime-apply',
            },
          };
        }
        return host.call(request);
      },
      events: host.events.stream,
    );
    final receipt = await client.command('profile.put', {
      'metadata': {'id': 'one', 'label': 'Renamed'},
      'expectedRevision': 1,
    });
    expect(receipt['revision'], 2);
    await host.close();
  });

  test('failed receipts become typed exceptions with their error code', () async {
    final host = ClientHost()
      ..operations.addAll({
        'newer': {
          'status': 'failed',
          'errorCode': 'superseded',
          'error': 'operation superseded',
        },
        'stopped': {'status': 'cancelled', 'error': 'operation cancelled'},
        'stale': {
          'status': 'failed',
          'errorCode': 'failed',
          'error': 'profile revision changed',
        },
      });
    final client = BackendClient(
      transport: host.call,
      events: host.events.stream,
    );
    await expectLater(
      client.wait('newer'),
      throwsA(
        isA<BackendException>()
            .having((e) => e.isSuperseded, 'isSuperseded', isTrue)
            .having((e) => e.operationId, 'operationId', 'newer'),
      ),
    );
    await expectLater(
      client.wait('stopped'),
      throwsA(
        isA<BackendException>().having(
          (e) => e.code,
          'code',
          BackendException.cancelled,
        ),
      ),
    );
    await expectLater(
      client.wait('stale'),
      throwsA(
        isA<BackendException>()
            .having((e) => e.isRevisionConflict, 'conflict', isTrue)
            .having((e) => '$e', 'text', 'profile revision changed'),
      ),
    );
    await host.close();
  });

  test('API errors keep their code and message without a Dart prefix', () async {
    final client = BackendClient(
      transport: (request) async => {
        'apiVersion': 1,
        'error': request['method'] == 'proxy.select'
            ? {
                'code': 'command_rejected',
                'errorCode': 'superseded',
                'message': 'operation superseded',
              }
            : {
                'code': 'invalid_request',
                'message': 'backend command queue is full',
              },
      },
      events: const Stream.empty(),
    );
    await expectLater(
      client.request('engine.command'),
      throwsA(
        isA<BackendException>()
            .having((e) => e.code, 'code', 'invalid_request')
            .having((e) => '$e', 'text', 'backend command queue is full'),
      ),
    );
    await expectLater(
      client.request('proxy.select'),
      throwsA(
        isA<BackendException>().having(
          (e) => e.isSuperseded,
          'isSuperseded',
          isTrue,
        ),
      ),
    );
  });

  test('user text hides superseded results and localizes the prefix', () {
    const labels = BackendErrorLabels(
      unavailable: 'Служба недоступна',
      failed: 'Ошибка',
      cancelled: 'Отменено',
      closed: 'Служба остановлена',
      timeout: 'Нет ответа',
    );
    const superseded = BackendException('superseded', 'operation superseded');
    expect(formatBackendError(superseded, labels), isEmpty);
    expect(isSilentBackendError(superseded), isTrue);
    // Where empty text means success, a command that never ran is cancelled.
    expect(
      formatBackendError(superseded, labels, reportSuperseded: true),
      'Отменено',
    );
    expect(
      formatBackendError(
        const BackendException('failed', 'operation failed'),
        labels,
      ),
      'Ошибка',
    );
    expect(
      formatBackendError(
        const BackendException('failed', 'profile revision changed'),
        labels,
      ),
      'Ошибка: profile revision changed',
    );
    expect(
      formatBackendError(
        const BackendException('unavailable', 'binder died'),
        labels,
      ),
      'Служба недоступна',
    );
    expect(
      formatBackendError(const BackendException('cancelled', ''), labels),
      'Отменено',
    );
    expect(
      formatBackendError(const BackendException('closed', 'closed'), labels),
      'Служба остановлена',
    );
    expect(
      formatBackendError(TimeoutException('pending'), labels),
      'Нет ответа',
    );
    expect(formatBackendError(StateError('raw cause'), labels), 'raw cause');
  });

  test('engine commands stay below the backend queue limit', () async {
    final host = ClientHost();
    final gate = Completer<void>();
    var running = 0;
    var peak = 0;
    final client = BackendClient(
      transport: (request) async {
        if (request['method'] != 'engine.command') return host.call(request);
        running++;
        peak = max(peak, running);
        await gate.future;
        running--;
        return {
          'apiVersion': 1,
          'result': {'status': 'succeeded'},
        };
      },
      events: host.events.stream,
    );
    final commands = [
      for (var i = 0; i < 10; i++)
        client.command('engine.command', {
          'method': 'provider.refresh',
          'params': {'name': 'provider-$i'},
        }),
    ];
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(running, BackendClient.engineCommandLimit);
    gate.complete();
    await Future.wait(commands);
    expect(peak, BackendClient.engineCommandLimit);
    expect(running, 0);
    await host.close();
  });

  test('a re-established binding resyncs events missed meanwhile', () async {
    final host = ClientHost();
    final reconnects = StreamController<void>.broadcast();
    final client = BackendClient(
      transport: host.call,
      events: host.events.stream,
      reconnects: reconnects.stream,
    );
    await client.attach();
    // The replacement process published its state before Dart re-registered.
    host
      ..instance = 'service-2'
      ..sequence = 3
      ..running = false;
    final resynced = client.changes.firstWhere(
      (snapshot) => (snapshot['runtime'] as Map)['instanceId'] == 'service-2',
    );
    reconnects.add(null);
    await resynced;
    expect((client.snapshot['runtime'] as Map)['desiredRunning'], false);
    await client.detach();
    await reconnects.close();
    await host.close();
  });
}
