import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flclashx/product/services/app_update_manifest.dart';

import 'release_contract.dart';

Future<void> main(List<String> args) async {
  final options = ManifestOptions.parse(args);
  final pubspecVersion = readPubspecVersion();
  final tagFailure = validateReleaseTag(
    refName: options.tagName,
    pubspecVersion: pubspecVersion,
  );
  final channelFailure = validateReleaseChannel(
    releaseChannel: options.channel.wireName,
    pubspecVersion: pubspecVersion,
  );
  final contractFailure = tagFailure ?? channelFailure;
  if (contractFailure != null) {
    throw StateError(contractFailure);
  }
  final signingKey = Platform.environment['APP_UPDATE_SIGNING_KEY'];
  if (signingKey == null || signingKey.isEmpty) {
    throw StateError('Missing APP_UPDATE_SIGNING_KEY.');
  }

  final manifest = await buildAppUpdateManifest(options);
  final manifestBytes = utf8.encode(
    '${const JsonEncoder.withIndent('  ').convert(manifest.toJson())}\n',
  );
  final signatureBytes = await signAppUpdateManifest(
    manifestBytes,
    signingKeyBase64: signingKey,
    expectedPublicKeyBase64: appUpdateManifestPublicKeyBase64,
  );

  final output = File(options.outputPath);
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(manifestBytes, flush: true);
  File('${options.outputPath}.sig')
      .writeAsBytesSync(signatureBytes, flush: true);
  stdout.writeln(
    'Wrote signed ${options.channel.wireName} app update manifest to '
    '`${options.outputPath}`.',
  );
}

Future<AppUpdateManifest> buildAppUpdateManifest(
  ManifestOptions options,
) async {
  final dist = Directory(options.distPath);
  if (!dist.existsSync()) {
    throw StateError('Missing dist directory `${options.distPath}`.');
  }
  final releaseNotes = File(options.releaseNotesPath);
  if (!releaseNotes.existsSync()) {
    throw StateError(
      'Missing release notes `${options.releaseNotesPath}`.',
    );
  }
  final releaseContract = readReleaseContract();
  final metadataFile = File(
    '${dist.path}${Platform.pathSeparator}'
    '${releaseContract.releaseMetadataFileName}',
  );
  final apkVersionCodes = metadataFile.existsSync()
      ? _readApkVersionCodes(metadataFile)
      : const <String, int>{};
  if (apkVersionCodes.isEmpty && options.versionCode == null) {
    throw StateError(
      'Release metadata with APK version codes is required unless '
      '--version-code is provided for manifest repair.',
    );
  }

  final assets = <AppUpdateManifestAsset>[];
  final files = dist
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.apk'))
      .toList()
    ..sort((left, right) => left.path.compareTo(right.path));
  for (final file in files) {
    final name = file.uri.pathSegments.last;
    if (!isAppUpdateAndroidApkAssetName(name)) {
      continue;
    }
    final digest = await sha256.bind(file.openRead()).first;
    final apkVersionCode = apkVersionCodes[name];
    if (apkVersionCodes.isNotEmpty && apkVersionCode == null) {
      throw StateError('Missing APK versionCode for `$name`.');
    }
    assets.add(
      AppUpdateManifestAsset(
        name: name,
        size: file.lengthSync(),
        sha256: digest.toString(),
        urls: [
          Uri.https(
            'sourceforge.net',
            '/projects/$sourceForgeProjectName/files/releases/'
                '${options.tagName}/$name/download',
          ).toString(),
          Uri.https(
            'github.com',
            '/${options.githubRepository}/releases/download/'
                '${options.tagName}/$name',
          ).toString(),
        ],
        versionCode: apkVersionCode,
      ),
    );
  }
  if (assets.isEmpty) {
    throw StateError('No Android APK assets found in `${options.distPath}`.');
  }

  final releaseVersionCode = options.versionCode ??
      assets.map((asset) => asset.versionCode!).reduce(
        (left, right) => left > right ? left : right,
      );
  return AppUpdateManifest(
    channel: options.channel,
    tagName: options.tagName,
    versionName: options.tagName.substring(1),
    versionCode: releaseVersionCode,
    publishedAt: options.publishedAt,
    body: releaseNotes.readAsStringSync(),
    htmlUrl: '$sourceForgeProjectUrl/files/releases/${options.tagName}/',
    assets: assets,
  );
}

Map<String, int> _readApkVersionCodes(File metadataFile) {
  final decoded = jsonDecode(metadataFile.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    throw StateError('Invalid release metadata `${metadataFile.path}`.');
  }
  final rawCodes = decoded['apkVersionCodes'];
  if (rawCodes is! Map) {
    return const {};
  }
  final result = <String, int>{};
  for (final entry in rawCodes.entries) {
    final name = entry.key.toString();
    final code = entry.value;
    if (name.isEmpty || code is! int || code <= 0) {
      throw StateError('Invalid APK version code in release metadata.');
    }
    result[name] = code;
  }
  final declaredVersionCode = decoded['versionCode'];
  final maximumVersionCode = result.values.reduce(
    (left, right) => left > right ? left : right,
  );
  if (declaredVersionCode != maximumVersionCode) {
    throw StateError(
      'Release metadata versionCode does not match APK version codes.',
    );
  }
  return result;
}

Future<List<int>> signAppUpdateManifest(
  List<int> manifestBytes, {
  required String signingKeyBase64,
  required String expectedPublicKeyBase64,
}) async {
  final seed = base64Decode(signingKeyBase64.trim());
  if (seed.length != 32) {
    throw const FormatException('App update signing key must be 32 bytes.');
  }
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(seed);
  final expectedPublicKey = base64Decode(expectedPublicKeyBase64);
  final actualPublicKey = await keyPair.extractPublicKey();
  if (!_bytesEqual(actualPublicKey.bytes, expectedPublicKey)) {
    throw const FormatException(
      'App update signing key does not match the embedded public key.',
    );
  }
  final signature = await algorithm.sign(
    manifestBytes,
    keyPair: keyPair,
  );
  return signature.bytes;
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

class ManifestOptions {
  const ManifestOptions({
    required this.distPath,
    required this.outputPath,
    required this.releaseNotesPath,
    required this.tagName,
    required this.githubRepository,
    required this.channel,
    required this.publishedAt,
    this.versionCode,
  });

  factory ManifestOptions.parse(List<String> args) {
    final values = <String, String>{};
    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      if (!arg.startsWith('--')) {
        throw ArgumentError('Unknown argument: $arg');
      }
      final separator = arg.indexOf('=');
      if (separator > 2) {
        values[arg.substring(2, separator)] = arg.substring(separator + 1);
        continue;
      }
      if (index + 1 >= args.length) {
        throw ArgumentError('Missing value for $arg');
      }
      values[arg.substring(2)] = args[++index];
    }

    String requiredValue(String key) {
      final value = values[key];
      if (value == null || value.isEmpty) {
        throw ArgumentError('Missing --$key.');
      }
      return value;
    }

    final channelName = requiredValue('channel');
    final channel = switch (channelName) {
      'stable' => AppUpdateChannel.stable,
      'pre' => AppUpdateChannel.prerelease,
      _ => throw ArgumentError('Expected --channel stable|pre.'),
    };
    final tagName = requiredValue('tag');
    if (!appUpdateReleaseTagPattern.hasMatch(tagName)) {
      throw ArgumentError('Invalid release tag `$tagName`.');
    }
    if (!appUpdateReleaseTagMatchesChannel(tagName, channel)) {
      throw ArgumentError('Release tag does not match channel `$channelName`.');
    }
    final publishedAt = DateTime.tryParse(requiredValue('published-at'));
    if (publishedAt == null || !publishedAt.isUtc) {
      throw ArgumentError('--published-at must be an ISO-8601 UTC timestamp.');
    }
    final rawVersionCode = values['version-code'];
    final versionCode =
        rawVersionCode == null ? null : int.tryParse(rawVersionCode);
    if (rawVersionCode != null && (versionCode == null || versionCode <= 0)) {
      throw ArgumentError('--version-code must be a positive integer.');
    }

    return ManifestOptions(
      distPath: requiredValue('dist'),
      outputPath: requiredValue('out'),
      releaseNotesPath: requiredValue('release-notes'),
      tagName: tagName,
      githubRepository: requiredValue('github-repository'),
      channel: channel,
      publishedAt: publishedAt,
      versionCode: versionCode,
    );
  }

  final String distPath;
  final String outputPath;
  final String releaseNotesPath;
  final String tagName;
  final String githubRepository;
  final AppUpdateChannel channel;
  final DateTime publishedAt;
  final int? versionCode;
}
