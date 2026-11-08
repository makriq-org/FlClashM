// Run: dart tool/benchmark_frontend_snapshot.dart
// Synthetic 1000-profile catalog; timings measure copying, not frame latency.
import 'dart:convert';
import 'dart:io';

import 'package:flclashx/product/backend/backend_client.dart';

Future<void> main() async {
  final snapshot = <String, dynamic>{
    'seq': 1,
    'runtime': {
      'instanceId': 'bench',
      'appliedGeneration': 1,
      'appliedRunning': true,
      'startedAt': 1,
    },
    'catalog': {
      'revision': 1,
      'settings': {'currentProfileId': 'profile-0'},
      'profiles': List.generate(
        1000,
        (i) => {
          'revision': 1,
          'metadata': {
            'id': 'profile-$i',
            'label': 'Subscription $i',
            'url': 'https://example.com/$i',
            'selectedMap': {'Proxy': 'Node $i'},
            'groups': List.generate(10, (j) => 'Group $j'),
          },
        },
      ),
    },
  };
  final client = BackendClient(
    transport: (r) async => {
      'apiVersion': 1,
      'result': r['method'] == 'snapshot' ? snapshot : <String, dynamic>{},
    },
    events: const Stream.empty(),
  );
  await client.attach();
  for (final entry in <String, Object? Function()>{
    'JSON snapshot': () => jsonDecode(jsonEncode(snapshot)),
    'direct snapshot': () => client.snapshot,
    'runtime only': () => client.runtime,
  }.entries) {
    for (var i = 0; i < 30; i++) {
      entry.value();
    }
    final samples = <int>[];
    for (var i = 0; i < 200; i++) {
      final watch = Stopwatch()..start();
      final value = entry.value();
      if (value == null) throw StateError('null');
      samples.add(watch.elapsedMicroseconds);
    }
    samples.sort();
    stdout.writeln('${entry.key}: median ${samples[100]} us, p95 ${samples[190]} us');
  }
  await client.detach();
}
