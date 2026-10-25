import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';
import 'package:flutter_test/flutter_test.dart';

import '../hook/build.dart' as hook;

void main() {
  late Directory llvmRoot;

  setUp(() {
    llvmRoot = Directory.systemTemp.createTempSync('rust-api-ndk-');
  });
  tearDown(() => llvmRoot.deleteSync(recursive: true));

  for (final layout in const {
    'lib/libclang.so': 'bin/clang',
    'lib64/libclang.so.18': 'bin/clang',
    'lib/libclang.dylib': 'bin/clang',
    'bin/libclang.dll': 'bin/clang.exe',
  }.entries) {
    test('finds NDK ${layout.key} next to the selected compiler', () {
      final library = File.fromUri(llvmRoot.uri.resolve(layout.key));
      library.parent.createSync(recursive: true);
      library.writeAsStringSync('');
      final compiler = llvmRoot.uri.resolve(layout.value);

      expect(hook.bindgenEnvironment(_input(compiler: compiler)), {
        'LIBCLANG_PATH': library.parent.path,
        'CLANG_PATH': File.fromUri(compiler).path,
      });
    });
  }

  test('does not search outside the selected LLVM toolchain', () {
    final unrelated = File.fromUri(
      llvmRoot.uri.resolve('other/lib/libclang.so'),
    );
    unrelated.parent.createSync(recursive: true);
    unrelated.writeAsStringSync('');

    expect(
      () => hook.bindgenEnvironment(
        _input(compiler: llvmRoot.uri.resolve('bin/clang')),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('leaves non-Android builds and missing compilers unchanged', () {
    expect(
      hook.bindgenEnvironment(
        _input(targetOS: OS.linux, compiler: llvmRoot.uri.resolve('bin/clang')),
      ),
      isEmpty,
    );
    expect(hook.bindgenEnvironment(_input()), isEmpty);
    expect(hook.bindgenEnvironment(_input(buildCodeAssets: false)), isEmpty);
  });
}

BuildInput _input({
  OS targetOS = OS.android,
  Uri? compiler,
  bool buildCodeAssets = true,
}) {
  final builder = BuildInputBuilder()
    ..setupShared(
      packageRoot: Directory.current.uri,
      packageName: 'rust_api',
      outputDirectoryShared: Directory.systemTemp.uri,
      outputFile: Directory.systemTemp.uri.resolve('rust-api-output.json'),
    )
    ..setupBuildInput();
  builder.config.setupBuild(linkingEnabled: false);
  if (buildCodeAssets) {
    builder.addExtension(
      CodeAssetExtension(
        targetArchitecture: Architecture.arm64,
        targetOS: targetOS,
        linkModePreference: LinkModePreference.dynamic,
        android: targetOS == OS.android
            ? AndroidCodeConfig(targetNdkApi: 23)
            : null,
        cCompiler: compiler == null
            ? null
            : CCompilerConfig(
                compiler: compiler,
                archiver: compiler.resolve('llvm-ar'),
                linker: compiler.resolve('ld.lld'),
              ),
      ),
    );
  }
  return builder.build();
}
