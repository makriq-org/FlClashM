// ignore_for_file: avoid_print

import 'dart:io';

const _appName = 'FlClashM';
const _coreDir = 'core';
const _distDir = 'dist';
const _libclashDir = 'libclash/android';
const _coreVersionFile = 'lib/core_version.dart';
const _ndkVersion = '28.0.13004108';

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
      '[--arch arm|arm64|amd64] [--env stable|pre] [--out app|core]',
    );
    exitCode = 64;
    return;
  }

  await _syncCoreVersionDartFile();
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

  if (out != 'app' && out != 'core') {
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
  final targetRoot = Directory(_join(_libclashDir));
  if (!targetRoot.existsSync()) {
    targetRoot.createSync(recursive: true);
  }

  final includesRoot = Directory(_join(_libclashDir, 'includes'));
  if (!includesRoot.existsSync()) {
    includesRoot.createSync(recursive: true);
  }

  for (final arch in arches) {
    final abiDir = Directory(_join(_libclashDir, arch.abi));
    if (abiDir.existsSync()) {
      abiDir.deleteSync(recursive: true);
    }
    abiDir.createSync(recursive: true);

    final includeDir = Directory(_join(_libclashDir, 'includes', arch.abi));
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
      workingDirectory: _coreDir,
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
  final dist = Directory(_join(_distDir));
  if (dist.existsSync()) {
    dist.deleteSync(recursive: true);
  }
  dist.createSync(recursive: true);

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
    name: 'flutter build apk (split)',
  );

  final splitDir = Directory(_join('build', 'app', 'outputs', 'flutter-apk'));
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
    name: 'flutter build appbundle',
  );
  File(
    _join('build', 'app', 'outputs', 'bundle', 'release', 'app-release.aab'),
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
    ...Directory(_coreDir).listSync(),
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
  final goMod = File(_join(_coreDir, 'go.mod'));
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
  final out = File(_join(_coreVersionFile));
  out.parent.createSync(recursive: true);
  await out.writeAsString(
    "// GENERATED by setup.dart from core/constant/version.go — do not edit by hand\n"
    "// ignore_for_file: constant_identifier_names\n\n"
    "/// Embedded mihomo version (see core/constant/version.go).\n"
    "const String kCoreVersionFromSource = '$version';\n",
  );
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
