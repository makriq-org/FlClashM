import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/sdk/build_sdk_summary.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;

/// Prepares a real Flutter SDK summary before invoking build_runner.
/// Nix resolves Flutter's Dart executable to a standalone SDK; build_runner's
/// sibling-directory detection then misses dart:ui. Resolve the embedder from
/// the Flutter package configuration instead. Never modify the shared pub cache.
Future<void> main(List<String> arguments) async {
  final configFile = File('.dart_tool/package_config.json').absolute;
  if (!configFile.existsSync()) {
    stderr.writeln('Run flutter pub get from the repository root first.');
    exitCode = 1;
    return;
  }
  final config = await loadPackageConfig(configFile);
  final sky = config['sky_engine'];
  if (sky == null) {
    stderr.writeln('sky_engine is missing; run flutter pub get with Flutter.');
    exitCode = 1;
    return;
  }
  final embedder = p.fromUri(sky.packageUriRoot.resolve('_embedder.yaml'));
  if (!File(embedder).existsSync()) {
    stderr.writeln('Flutter embedder is missing: $embedder');
    exitCode = 1;
    return;
  }
  final summary = await buildSdkSummary(
    sdkPath: p.dirname(p.dirname(Platform.resolvedExecutable)),
    resourceProvider: PhysicalResourceProvider.INSTANCE,
    embedderYamlPath: embedder,
  );
  final cache = Directory('.dart_tool/build_resolvers');
  await cache.create(recursive: true);
  await File(p.join(cache.path, 'sdk.sum')).writeAsBytes(summary, flush: true);
  // Match build_runner's cache identity exactly. Rebuild on each wrapper run so
  // a changed Flutter embedder is also picked up with an unchanged Dart SDK.
  await File(p.join(cache.path, 'sdk.sum.deps')).writeAsString(
    jsonEncode({
      'sdk': Platform.version,
      for (final name in ['analyzer', 'build_runner'])
        name: p.dirname(p.fromUri(config[name]!.packageUriRoot)),
    }),
    flush: true,
  );
  stdout.writeln('Flutter SDK summary: $embedder');
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    'build_runner',
    ...arguments.isEmpty ? ['build'] : arguments,
  ], mode: ProcessStartMode.inheritStdio);
  exitCode = await process.exitCode;
}
