import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flclashx/product/services/app_update_manifest.dart';

import 'release_contract.dart';
import 'write_app_update_manifest.dart' show signAppUpdateManifest;

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  final version = readPubspecVersion();
  final failure = validateReleaseTag(
        refName: options.tag,
        pubspecVersion: version,
      ) ??
      validateReleaseChannel(
        releaseChannel: options.channel.wireName,
        pubspecVersion: version,
      );
  if (failure != null) throw StateError(failure);
  final key = Platform.environment['APP_UPDATE_SIGNING_KEY'];
  if (key == null || key.isEmpty) {
    throw StateError('Missing APP_UPDATE_SIGNING_KEY.');
  }

  final assets = await _assets(options);
  if (assets.isEmpty) {
    throw StateError('No desktop update packages found in `${options.dist}`.');
  }
  final catalog = <String, Object?>{
    'schemaVersion': 1,
    'catalogId': sha256
        .convert(utf8.encode('${options.tag}:${options.channel.wireName}'))
        .toString()
        .substring(0, 32),
    'channel': options.channel.wireName,
    'release': <String, Object?>{
      'tagName': options.tag,
      'versionName': options.tag.substring(1),
      'versionCode': version.versionCode,
      'publishedAt': options.publishedAt.toIso8601String(),
      'body': File(options.releaseNotes).readAsStringSync(),
      'htmlUrl': '$sourceForgeProjectUrl/files/releases/${options.tag}/',
      'assets': assets,
    },
  };
  final bytes = utf8.encode('${const JsonEncoder.withIndent('  ').convert(catalog)}\n');
  final signature = await signAppUpdateManifest(
    bytes,
    signingKeyBase64: key,
    expectedPublicKeyBase64: appUpdateManifestPublicKeyBase64,
  );
  final output = File(options.output);
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(bytes, flush: true);
  File('${output.path}.sig').writeAsBytesSync(signature, flush: true);
}

Future<List<Map<String, Object>>> _assets(_Options options) async {
  const targets = <String, (String, String, String)> {
    'FlClashM-linux-x64.AppImage': ('linux', 'x86_64', 'appimage'),
    'FlClashM-windows-x64-setup.exe': ('windows', 'x86_64', 'windows-installer'),
    'FlClashM-macos-x64.zip': ('macos', 'x86_64', 'macos-app-archive'),
    'FlClashM-macos-arm64.zip': ('macos', 'arm64', 'macos-app-archive'),
  };
  final assets = <Map<String, Object>>[];
  for (final entry in targets.entries) {
    final file = File('${options.dist}/${entry.key}');
    if (!file.existsSync()) continue;
    final target = entry.value;
    final digest = await sha256.bind(file.openRead()).first;
    assets.add(<String, Object>{
      'os': target.$1,
      'arch': target.$2,
      'packageKind': target.$3,
      'name': entry.key,
      'size': file.lengthSync(),
      'sha256': digest.toString(),
      'urls': <String>[
        Uri.https(
          'sourceforge.net',
          '/projects/$sourceForgeProjectName/files/releases/${options.tag}/${entry.key}/download',
        ).toString(),
        Uri.https(
          'github.com',
          '/${options.repository}/releases/download/${options.tag}/${entry.key}',
        ).toString(),
      ],
    });
  }
  return assets;
}

class _Options {
  const _Options({
    required this.dist,
    required this.output,
    required this.releaseNotes,
    required this.tag,
    required this.repository,
    required this.channel,
    required this.publishedAt,
  });

  factory _Options.parse(List<String> args) {
    final values = <String, String>{};
    for (var index = 0; index < args.length; index++) {
      final argument = args[index];
      if (!argument.startsWith('--') || index + 1 >= args.length) {
        throw ArgumentError('Expected --name value options.');
      }
      values[argument.substring(2)] = args[++index];
    }
    String required(String name) => values[name]?.trim().isNotEmpty == true
        ? values[name]!
        : throw ArgumentError('Missing --$name.');
    final channel = switch (required('channel')) {
      'stable' => AppUpdateChannel.stable,
      'pre' => AppUpdateChannel.prerelease,
      _ => throw ArgumentError('Expected --channel stable|pre.'),
    };
    final publishedAt = DateTime.tryParse(required('published-at'));
    if (publishedAt == null || !publishedAt.isUtc) {
      throw ArgumentError('Expected a UTC --published-at timestamp.');
    }
    return _Options(
      dist: required('dist'),
      output: required('out'),
      releaseNotes: required('release-notes'),
      tag: required('tag'),
      repository: required('github-repository'),
      channel: channel,
      publishedAt: publishedAt,
    );
  }

  final String dist;
  final String output;
  final String releaseNotes;
  final String tag;
  final String repository;
  final AppUpdateChannel channel;
  final DateTime publishedAt;
}
