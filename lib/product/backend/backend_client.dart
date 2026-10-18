import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

typedef BackendTransport =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> request);

/// Local UI client. It submits user actions and projects snapshots; it has no
/// compiler, runtime executor, recovery timer or subscription scheduler.
class BackendClient {
  BackendClient({required this._transport, required this._events});

  final BackendTransport _transport;
  final Stream<Map<String, dynamic>> _events;
  final _changes = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final _random = Random.secure();
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Future<void>? _refreshing;
  bool _refreshAgain = false;
  Map<String, dynamic> _snapshot = {};
  Map<String, dynamic> _view = {};
  String _instance = '';
  int _sequence = -1;

  Stream<Map<String, dynamic>> get changes => _changes.stream;
  Map<String, dynamic> get snapshot => _copy(_snapshot);
  Map<String, dynamic> get runtimeView => _copy(_view);
  bool get attached => _subscription != null;

  String operationId() =>
      'ui-${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<void> attach() async {
    _subscription ??= _events.listen(_event);
    await refresh();
  }

  Future<void> detach() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<dynamic> request(
    String method, [
    Map<String, dynamic>? params,
    String? id,
  ]) async {
    final response = await _transport({
      'apiVersion': 1,
      'operationId': id ?? operationId(),
      'method': method,
      'params': ?params,
    });
    if (response['apiVersion'] != 1) {
      throw StateError('Unsupported backend API version');
    }
    final error = response['error'];
    if (error is Map) {
      throw StateError('${error['message']}');
    }
    return response['result'];
  }

  /// Waiting belongs to the UI. Timeout or detachment never cancels the Go
  /// operation; cancellation is a separate, explicit command.
  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, dynamic>? params,
    String? id,
  ]) async {
    final operation = id ?? operationId();
    final receipt = _map(await request(method, params, operation));
    final completed = await wait(operation, initial: receipt);
    final runtimeOperation = completed['runtimeOperationId'];
    if (runtimeOperation is String && runtimeOperation.isNotEmpty) {
      await wait(runtimeOperation);
    }
    await refresh();
    return completed;
  }

  Future<Map<String, dynamic>> wait(
    String operation, {
    Map<String, dynamic>? initial,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var receipt =
        initial ??
        _map(await request('operation.get', {'operationId': operation}));
    while (receipt['status'] == 'accepted') {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Backend operation is still pending', timeout);
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
      receipt = _map(
        await request('operation.get', {'operationId': operation}),
      );
    }
    if (receipt['status'] != 'succeeded') {
      throw StateError('${receipt['error'] ?? receipt['status']}');
    }
    return receipt;
  }

  Future<bool> cancel(String operation) async =>
      await request('operation.cancel', {'operationId': operation}) == true;

  Future<void> refresh() {
    final running = _refreshing;
    if (running != null) {
      _refreshAgain = true;
      return running;
    }
    final task = _refreshLoop();
    _refreshing = task;
    return task.whenComplete(() {
      if (identical(_refreshing, task)) {
        _refreshing = null;
      }
    });
  }

  Future<void> _refreshLoop() async {
    do {
      _refreshAgain = false;
      final first = _map(await request('snapshot'));
      final view = _map(await request('runtime.view'));
      final second = _map(await request('snapshot'));
      final firstRuntime = _map(first['runtime']);
      final nextRuntime = _map(second['runtime']);
      if (firstRuntime['instanceId'] != nextRuntime['instanceId'] ||
          firstRuntime['appliedGeneration'] !=
              nextRuntime['appliedGeneration']) {
        _refreshAgain = true;
        continue;
      }
      final instance = nextRuntime['instanceId'] as String? ?? '';
      final sequence = (second['seq'] as num?)?.toInt() ?? -1;
      if (instance == _instance && sequence < _sequence) {
        _refreshAgain = true;
        continue;
      }
      _instance = instance;
      _sequence = sequence;
      _snapshot = _copy(second);
      _view = _copy(view);
      _changes.add(snapshot);
    } while (_refreshAgain);
  }

  void _event(Map<String, dynamic> event) {
    final runtime = _map(event['runtime']);
    final instance = runtime['instanceId'] as String? ?? '';
    final sequence = (event['seq'] as num?)?.toInt() ?? -1;
    if (event['apiVersion'] != 1 || instance != _instance) {
      _resync();
      return;
    }
    if (sequence <= _sequence) {
      return;
    }
    _sequence = sequence;
    final previous = _map(_snapshot['runtime']);
    _snapshot = {..._snapshot, 'runtime': _copy(runtime), 'seq': sequence};
    _changes.add(snapshot);
    final catalog = _map(_snapshot['catalog']);
    if (event['resyncRequired'] == true ||
        event['catalogRevision'] != catalog['revision'] ||
        runtime['appliedGeneration'] != previous['appliedGeneration']) {
      _resync();
    }
  }

  void _resync() {
    unawaited(
      refresh().catchError((Object error, StackTrace stack) {
        _changes.addError(error, stack);
      }),
    );
  }

  Map<String, dynamic> get settings {
    final catalog = _map(_snapshot['catalog']);
    return {
      ..._copy(_map(catalog['settings'])),
      'profiles': [
        for (final record in (catalog['profiles'] as List? ?? []))
          _copy(_map(_map(record)['metadata'])),
      ],
    };
  }

  int profileRevision(String id) {
    for (final record
        in (_map(_snapshot['catalog'])['profiles'] as List? ?? [])) {
      final row = _map(record);
      if (_map(row['metadata'])['id'] == id) {
        return (row['revision'] as num?)?.toInt() ?? 0;
      }
    }
    return 0;
  }

  int get catalogRevision =>
      (_map(_snapshot['catalog'])['revision'] as num?)?.toInt() ?? 0;

  Future<Map<String, dynamic>> profile(String id) async =>
      _map(await request('profile.get', {'profileId': id}));

  Future<Uint8List> exportProfile(String id) async {
    final receipt = await command('profile.export', {'profileId': id});
    final blob = _map(receipt['blob']);
    final token = blob['token'] as String;
    try {
      return await download(token, (blob['size'] as num).toInt());
    } finally {
      await request('blob.delete', {'token': token});
    }
  }

  Future<Map<String, dynamic>> saveSource(
    Map<String, dynamic> metadata,
    Uint8List source, {
    required int expectedRevision,
    bool select = false,
  }) async {
    final token = await upload(source);
    try {
      return await command('profile.import.file', {
        'metadata': metadata,
        'token': token,
        'expectedRevision': expectedRevision,
        'select': select,
      });
    } finally {
      await request('blob.delete', {'token': token});
    }
  }

  Future<String> upload(Uint8List bytes) async {
    final blob = _map(await request('blob.create'));
    final token = blob['token'] as String;
    try {
      for (var offset = 0; offset < bytes.length; offset += 192 * 1024) {
        final end = min(bytes.length, offset + 192 * 1024);
        await request('blob.append', {
          'token': token,
          'offset': offset,
          'data': base64Encode(Uint8List.sublistView(bytes, offset, end)),
        });
      }
      return token;
    } catch (_) {
      await request('blob.delete', {'token': token});
      rethrow;
    }
  }

  Future<Uint8List> download(String token, int size) async {
    final bytes = BytesBuilder(copy: false);
    while (bytes.length < size) {
      final part = _map(
        await request('blob.read', {
          'token': token,
          'offset': bytes.length,
          'limit': 192 * 1024,
        }),
      );
      final chunk = base64Decode(part['data'] as String);
      if (chunk.isEmpty || bytes.length + chunk.length > size) {
        throw StateError('Invalid backend transfer');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  static Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};
  static Map<String, dynamic> _copy(Map<String, dynamic> value) =>
      _map(jsonDecode(jsonEncode(value)));
}
