// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flclashx/product/runtime/naiveproxy_release.dart';

const _appName = 'FlClashM';
const _coreDir = 'core';
const _distDir = 'dist';
const _libclashDir = 'libclash/android';
const _coreVersionFile = 'lib/core_version.dart';
const _ndkVersion = '28.0.13004108';
const _naiveProxyStampFile = 'assets/runtimes/naiveproxy/android/release.txt';
final _projectRoot = File.fromUri(Platform.script).parent.absolute.path;

final _androidArches = <String, AndroidArch>{
  'arm': const AndroidArch(
    cliName: 'arm',
    abi: 'armeabi-v7a',
    goArch: 'arm',
    goArm: '7',
    toolchain: 'armv7a-linux-androideabi21-clang',
  ),
  'arm64': const AndroidArch(
    cliName: 'arm64',
    abi: 'arm64-v8a',
    goArch: 'arm64',
    toolchain: 'aarch64-linux-android21-clang',
  ),
  'amd64': const AndroidArch(
    cliName: 'amd64',
    abi: 'x86_64',
    goArch: 'amd64',
    toolchain: 'x86_64-linux-android21-clang',
  ),
};

class AndroidArch {
  const AndroidArch({
    required this.cliName,
    required this.abi,
    required this.goArch,
    required this.toolchain,
    this.goArm,
  });

  final String cliName;
  final String abi;
  final String goArch;
  final String toolchain;
  final String? goArm;
}

Future<void> main(List<String> args) async {
  final command = _parseArgs(args);
  if (command.target != 'android') {
    stderr.writeln(
      'FlClashM is Android-only. Supported command: dart setup.dart android '
      '[--arch arm|arm64|amd64] [--env stable|pre] '
      '[--out app|core|runtime-assets]',
    );
    exitCode = 64;
    return;
  }

  await _syncCoreVersionDartFile();
  await _syncNaiveProxyAssets();
  if (command.out == 'runtime-assets') {
    return;
  }
  final coreVersion = await _extractCoreVersion();
  final arches = command.arch == null
      ? _androidArches.values.toList()
      : [_requireArch(command.arch!)];

  await _buildAndroidCore(arches: arches, coreVersion: coreVersion);

  if (command.out == 'app') {
    await _buildAndroidArtifacts(
      env: command.env,
      coreVersion: coreVersion,
    );
  }
}

CommandArgs _parseArgs(List<String> args) {
  if (args.isEmpty) {
    return const CommandArgs(target: '');
  }

  var arch = '';
  var env = 'pre';
  var out = 'app';

  for (var i = 1; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--arch':
        if (i + 1 >= args.length) {
          throw ArgumentError('Missing value for --arch');
        }
        arch = args[++i];
        break;
      case '--env':
        if (i + 1 >= args.length) {
          throw ArgumentError('Missing value for --env');
        }
        env = args[++i];
        break;
      case '--out':
        if (i + 1 >= args.length) {
          throw ArgumentError('Missing value for --out');
        }
        out = args[++i];
        break;
      default:
        throw ArgumentError('Unknown argument: $arg');
    }
  }

  if (out != 'app' && out != 'core' && out != 'runtime-assets') {
    throw ArgumentError('Invalid --out value: $out');
  }

  if (env != 'stable' && env != 'pre') {
    throw ArgumentError('Invalid --env value: $env');
  }

  return CommandArgs(
    target: args.first,
    arch: arch.isEmpty ? null : arch,
    env: env,
    out: out,
  );
}

AndroidArch _requireArch(String name) {
  final arch = _androidArches[name];
  if (arch == null) {
    throw ArgumentError(
      'Unsupported Android arch "$name". '
      'Use one of: ${_androidArches.keys.join(', ')}',
    );
  }
  return arch;
}

Future<void> _buildAndroidCore({
  required List<AndroidArch> arches,
  required String coreVersion,
}) async {
  final ndkBin = _resolveNdkBinDir();
  final targetRoot = Directory(_projectPath(_libclashDir));
  if (!targetRoot.existsSync()) {
    targetRoot.createSync(recursive: true);
  }

  final includesRoot = Directory(_projectPath(_libclashDir, 'includes'));
  if (!includesRoot.existsSync()) {
    includesRoot.createSync(recursive: true);
  }

  for (final arch in arches) {
    final abiDir = Directory(_projectPath(_libclashDir, arch.abi));
    if (abiDir.existsSync()) {
      abiDir.deleteSync(recursive: true);
    }
    abiDir.createSync(recursive: true);

    final includeDir =
        Directory(_projectPath(_libclashDir, 'includes', arch.abi));
    if (includeDir.existsSync()) {
      includeDir.deleteSync(recursive: true);
    }
    includeDir.createSync(recursive: true);

    final env = <String, String>{
      ...Platform.environment,
      'GOOS': 'android',
      'GOARCH': arch.goArch,
      'CGO_ENABLED': '1',
      'CC': _join(ndkBin.path, arch.toolchain),
      'CFLAGS': '-O3 -Werror',
    };
    if (arch.goArm != null) {
      env['GOARM'] = arch.goArm!;
    }

    final outFile = _join(abiDir.path, 'libclash.so');
    await _exec(
      [
        'go',
        'build',
        '-ldflags=-w -s -X github.com/metacubex/mihomo/constant.Version=$coreVersion',
        '-tags=with_gvisor,cmfa',
        '-buildmode=c-shared',
        '-o',
        outFile,
      ],
      environment: env,
      workingDirectory: _projectPath(_coreDir),
      name: 'build android core ${arch.abi}',
    );

    _collectHeaders(
      abiDir: abiDir,
      includeDir: includeDir,
    );
  }
}

Future<void> _buildAndroidArtifacts({
  required String env,
  required String coreVersion,
}) async {
  final dist = Directory(_projectPath(_distDir));
  if (dist.existsSync()) {
    dist.deleteSync(recursive: true);
  }
  dist.createSync(recursive: true);
  final flutterEnvironment = _buildFlutterEnvironment();

  await _exec(
    [
      'flutter',
      'build',
      'apk',
      '--release',
      '--split-per-abi',
      '--dart-define=APP_ENV=$env',
      '--dart-define=CORE_VERSION=$coreVersion',
    ],
    environment: flutterEnvironment,
    workingDirectory: _projectRoot,
    name: 'flutter build apk (split)',
  );

  final splitDir = Directory(
    _projectPath('build', 'app', 'outputs', 'flutter-apk'),
  );
  final splitNames = <String, String>{
    'app-arm64-v8a-release.apk': '$_appName-android-arm64-v8a.apk',
    'app-armeabi-v7a-release.apk': '$_appName-android-armeabi-v7a.apk',
    'app-x86_64-release.apk': '$_appName-android-x86_64.apk',
  };
  for (final entity in splitDir.listSync()) {
    final name = _basename(entity.path);
    final targetName = splitNames[name];
    if (targetName != null && entity is File) {
      entity.copySync(_join(dist.path, targetName));
    }
  }

  await _exec(
    [
      'flutter',
      'build',
      'apk',
      '--release',
      '--dart-define=APP_ENV=$env',
      '--dart-define=CORE_VERSION=$coreVersion',
    ],
    environment: flutterEnvironment,
    workingDirectory: _projectRoot,
    name: 'flutter build apk (universal)',
  );
  File(_join(splitDir.path, 'app-release.apk')).copySync(
    _join(dist.path, '$_appName-android-universal.apk'),
  );

  await _exec(
    [
      'flutter',
      'build',
      'appbundle',
      '--release',
      '--dart-define=APP_ENV=$env',
      '--dart-define=CORE_VERSION=$coreVersion',
    ],
    environment: flutterEnvironment,
    workingDirectory: _projectRoot,
    name: 'flutter build appbundle',
  );
  File(
    _projectPath(
        'build', 'app', 'outputs', 'bundle', 'release', 'app-release.aab'),
  ).copySync(_join(dist.path, '$_appName-android-release.aab'));
}

Directory _resolveNdkBinDir() {
  final explicit = Platform.environment['ANDROID_NDK'];
  if (explicit != null && explicit.isNotEmpty) {
    return _findNdkBinDir(explicit);
  }

  final ndkHome = Platform.environment['ANDROID_NDK_HOME'];
  if (ndkHome != null && ndkHome.isNotEmpty) {
    return _findNdkBinDir(ndkHome);
  }

  final sdkRoot = Platform.environment['ANDROID_SDK_ROOT'] ??
      Platform.environment['ANDROID_HOME'];
  if (sdkRoot == null || sdkRoot.isEmpty) {
    throw StateError(
      'ANDROID_NDK or ANDROID_SDK_ROOT/ANDROID_HOME must be configured.',
    );
  }

  final ndkDir = Directory(_join(sdkRoot, 'ndk', _ndkVersion));
  if (!ndkDir.existsSync()) {
    throw StateError('Android NDK $_ndkVersion not found in ${ndkDir.path}.');
  }

  return _findNdkBinDir(ndkDir.path);
}

Directory _findNdkBinDir(String ndkRoot) {
  final prebuiltRoot = Directory(
    _join(ndkRoot, 'toolchains', 'llvm', 'prebuilt'),
  );
  if (!prebuiltRoot.existsSync()) {
    throw StateError('NDK prebuilt directory not found in $ndkRoot.');
  }

  final hostDirs = prebuiltRoot.listSync().whereType<Directory>().toList();
  if (hostDirs.isEmpty) {
    throw StateError('Unable to resolve NDK host toolchain in $ndkRoot.');
  }

  return Directory(_join(hostDirs.first.path, 'bin'));
}

void _collectHeaders({
  required Directory abiDir,
  required Directory includeDir,
}) {
  final headerCandidates = [
    ...abiDir.listSync(),
    ...Directory(_projectPath(_coreDir)).listSync(),
  ];

  for (final entity in headerCandidates) {
    if (entity is! File || !entity.path.endsWith('.h')) {
      continue;
    }
    final target = File(_join(includeDir.path, _basename(entity.path)));
    target.parent.createSync(recursive: true);
    entity.copySync(target.path);
    if (entity.path.startsWith(abiDir.path)) {
      entity.deleteSync();
    }
  }
}

Future<String> _extractCoreVersion() async {
  final goMod = File(_projectPath(_coreDir, 'go.mod'));
  if (!goMod.existsSync()) {
    throw StateError('core/go.mod file not found');
  }
  final content = await goMod.readAsString();
  final match = RegExp(
    r'github\.com/metacubex/mihomo\s+(v[\d.]+)',
  ).firstMatch(content);
  if (match == null) {
    throw StateError('Could not extract mihomo version from core/go.mod');
  }
  return match.group(1)!;
}

Future<void> _syncCoreVersionDartFile() async {
  final version = await _extractCoreVersion();
  final out = File(_projectPath(_coreVersionFile));
  out.parent.createSync(recursive: true);
  await out.writeAsString(
    "// GENERATED by setup.dart from core/constant/version.go — do not edit by hand\n"
    "// ignore_for_file: constant_identifier_names\n\n"
    "/// Embedded mihomo version (see core/constant/version.go).\n"
    "const String kCoreVersionFromSource = '$version';\n",
  );
}

Future<void> _syncNaiveProxyAssets() async {
  final stamp = File(_projectPath(_naiveProxyStampFile));
  final expectedStamp = _buildNaiveProxyStamp();
  final assetFilesExist = naiveProxyReleaseAssets.values.every(
    (asset) => File(_projectPath(asset.bundledAssetPath)).existsSync(),
  );

  if (assetFilesExist &&
      stamp.existsSync() &&
      (await stamp.readAsString()).trim() == expectedStamp) {
    return;
  }

  final targetRoot = Directory(_projectPath(naiveProxyBundledAssetRoot));
  if (!targetRoot.existsSync()) {
    targetRoot.createSync(recursive: true);
  }

  for (final asset in naiveProxyReleaseAssets.values) {
    final target = File(_projectPath(asset.bundledAssetPath));
    target.parent.createSync(recursive: true);
    final apkBytes = await _downloadBytes(Uri.parse(asset.downloadUrl));
    final apkSha256 = sha256.convert(apkBytes).toString();
    if (apkSha256 != asset.apkSha256) {
      throw StateError(
        'naiveproxy asset digest mismatch for ${asset.apkName}: '
        'expected ${asset.apkSha256}, got $apkSha256',
      );
    }

    final archive = ZipDecoder().decodeBytes(apkBytes, verify: true);
    final binary = archive.findFile('lib/${asset.abi}/libnaive.so');
    if (binary == null) {
      throw StateError(
        'lib/${asset.abi}/libnaive.so not found in ${asset.apkName}',
      );
    }

    await target.writeAsBytes(
      Uint8List.fromList(binary.content as List<int>),
      flush: true,
    );
  }

  stamp.parent.createSync(recursive: true);
  await stamp.writeAsString(expectedStamp, flush: true);
}

String _buildNaiveProxyStamp() {
  final lines = <String>[
    naiveProxyPinnedReleaseTag,
    ...naiveProxyReleaseAssets.values.map(
      (asset) => '${asset.abi}:${asset.apkName}:${asset.apkSha256}',
    ),
  ];
  return lines.join('\n');
}

Future<Uint8List> _downloadBytes(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Unexpected HTTP ${response.statusCode} for $uri',
        uri: uri,
      );
    }

    final bytes = BytesBuilder(copy: false);
    await response.forEach(bytes.add);
    return bytes.takeBytes();
  } finally {
    client.close(force: true);
  }
}

Map<String, String> _buildFlutterEnvironment() {
  final env = <String, String>{...Platform.environment};
  final aapt2Override = _resolveNixAapt2Override();
  if (aapt2Override == null) {
    return env;
  }

  const aapt2Property = 'android.aapt2FromMavenOverride=';
  final existingGradleOpts = env['GRADLE_OPTS']?.trim();
  if (existingGradleOpts != null &&
      existingGradleOpts.contains(aapt2Property)) {
    return env;
  }

  final overrideOption =
      '-Dorg.gradle.project.android.aapt2FromMavenOverride=$aapt2Override';
  env['GRADLE_OPTS'] =
      (existingGradleOpts == null || existingGradleOpts.isEmpty)
          ? overrideOption
          : '$existingGradleOpts $overrideOption';
  stdout.writeln('use NixOS aapt2 override: $aapt2Override');
  return env;
}

String? _resolveNixAapt2Override() {
  if (!Platform.isLinux || !File('/etc/NIXOS').existsSync()) {
    return null;
  }

  final sdkRoot = Platform.environment['ANDROID_SDK_ROOT'] ??
      Platform.environment['ANDROID_HOME'];
  if (sdkRoot == null || sdkRoot.isEmpty) {
    return null;
  }

  final candidate = File(_join(sdkRoot, 'build-tools', '34.0.0', 'aapt2'));
  if (!candidate.existsSync()) {
    return null;
  }
  return candidate.path;
}

Future<void> _exec(
  List<String> command, {
  required String name,
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  print('run $name');
  final process = await Process.start(
    command.first,
    command.sublist(1),
    workingDirectory: workingDirectory,
    environment: environment,
    runInShell: true,
  );

  await Future.wait([
    stdout.addStream(process.stdout),
    stderr.addStream(process.stderr),
  ]);
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw ProcessException(
        command.first, command.sublist(1), '$name failed', exitCode);
  }
}

String _join(
  String first, [
  String? second,
  String? third,
  String? fourth,
  String? fifth,
  String? sixth,
]) {
  final parts = [first, second, third, fourth, fifth, sixth]
      .whereType<String>()
      .where((part) => part.isNotEmpty)
      .toList();
  return parts.join(Platform.pathSeparator);
}

String _projectPath(
  String first, [
  String? second,
  String? third,
  String? fourth,
  String? fifth,
  String? sixth,
]) =>
    _join(
      _join(_projectRoot, first, second, third, fourth, fifth),
      sixth,
    );

String _basename(String path) {
  final normalized = path.replaceAll(r'\', '/');
  final parts = normalized.split('/');
  return parts.isEmpty ? path : parts.last;
}

class CommandArgs {
  const CommandArgs({
    required this.target,
    this.arch,
    this.env = 'pre',
    this.out = 'app',
  });

  final String target;
  final String? arch;
  final String env;
  final String out;
}
