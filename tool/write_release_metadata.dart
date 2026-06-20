import 'dart:convert';
import 'dart:io';

import 'release_contract.dart';

void main(List<String> args) {
  final options = MetadataOptions.parse(args);
  final contract = readReleaseContract();
  final pubspecVersion = readPubspecVersion();
  final coreVersion = readCoreVersion();

  final outputFile = File(options.outputPath);
  outputFile.parent.createSync(recursive: true);
  outputFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'appName': contract.appName,
      'applicationId': contract.applicationId,
      'releaseRepository': contract.releaseRepository,
      'githubRepository': options.githubRepository,
      'tagName': options.githubRefName,
      'expectedStableTag': 'v${pubspecVersion.versionName}',
      'releaseChannel': options.releaseChannel,
      'pubspecVersion': pubspecVersion.raw,
      'versionName': pubspecVersion.versionName,
      'versionCode': pubspecVersion.versionCode,
      'coreVersion': coreVersion,
      'commitSha': options.githubSha,
      'releaseArtifacts': contract.releaseArtifacts,
      'releaseMetadataFileName': contract.releaseMetadataFileName,
    }),
  );

  stdout.writeln('Wrote release metadata to `${outputFile.path}`.');
}

class MetadataOptions {
  const MetadataOptions({
    required this.outputPath,
    required this.githubRefName,
    required this.githubSha,
    required this.githubRepository,
    required this.releaseChannel,
  });

  factory MetadataOptions.parse(List<String> args) {
    String? outputPath;
    String? githubRefName;
    String? githubSha;
    String? githubRepository;
    String? releaseChannel;

    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      if (arg == '--out') {
        outputPath = _requireValue(args, index, '--out');
        index++;
        continue;
      }
      if (arg.startsWith('--out=')) {
        outputPath = arg.substring('--out='.length);
        continue;
      }
      if (arg == '--github-ref-name') {
        githubRefName = _requireValue(args, index, '--github-ref-name');
        index++;
        continue;
      }
      if (arg.startsWith('--github-ref-name=')) {
        githubRefName = arg.substring('--github-ref-name='.length);
        continue;
      }
      if (arg == '--github-sha') {
        githubSha = _requireValue(args, index, '--github-sha');
        index++;
        continue;
      }
      if (arg.startsWith('--github-sha=')) {
        githubSha = arg.substring('--github-sha='.length);
        continue;
      }
      if (arg == '--github-repository') {
        githubRepository = _requireValue(args, index, '--github-repository');
        index++;
        continue;
      }
      if (arg.startsWith('--github-repository=')) {
        githubRepository = arg.substring('--github-repository='.length);
        continue;
      }
      if (arg == '--release-channel') {
        releaseChannel = _requireValue(args, index, '--release-channel');
        index++;
        continue;
      }
      if (arg.startsWith('--release-channel=')) {
        releaseChannel = arg.substring('--release-channel='.length);
        continue;
      }
      throw ArgumentError('Unknown argument: $arg');
    }

    if (outputPath == null || outputPath.isEmpty) {
      throw ArgumentError('Missing required `--out` argument.');
    }
    if (githubRefName == null || githubRefName.isEmpty) {
      throw ArgumentError('Missing required `--github-ref-name` argument.');
    }
    if (githubSha == null || githubSha.isEmpty) {
      throw ArgumentError('Missing required `--github-sha` argument.');
    }
    if (githubRepository == null || githubRepository.isEmpty) {
      throw ArgumentError(
        'Missing required `--github-repository` argument.',
      );
    }
    final checkedReleaseChannel = releaseChannel;
    if (checkedReleaseChannel == null ||
        (checkedReleaseChannel != 'stable' && checkedReleaseChannel != 'pre')) {
      throw ArgumentError(
        'Expected `--release-channel stable|pre`, got `${releaseChannel ?? ''}`.',
      );
    }

    return MetadataOptions(
      outputPath: outputPath,
      githubRefName: githubRefName,
      githubSha: githubSha,
      githubRepository: githubRepository,
      releaseChannel: checkedReleaseChannel,
    );
  }

  final String outputPath;
  final String githubRefName;
  final String githubSha;
  final String githubRepository;
  final String releaseChannel;
}

String _requireValue(List<String> args, int index, String flag) {
  if (index + 1 >= args.length) {
    throw ArgumentError('Missing value for $flag');
  }
  return args[index + 1];
}
