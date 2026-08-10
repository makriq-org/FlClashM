import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/product/platform/product_install_layout.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

class AppPath {
  factory AppPath() {
    _instance ??= AppPath._internal();
    return _instance!;
  }

  AppPath._internal() {
    appDirPath = join(dirname(Platform.resolvedExecutable));
    getApplicationSupportDirectory().then((value) {
      dataDir.complete(value);
    }).catchError((e) {
      dataDir.completeError(e);
    });
    getTemporaryDirectory().then((value) {
      tempDir.complete(value);
    }).catchError((e) {
      tempDir.completeError(e);
    });
    getDownloadsDirectory().then((value) {
      downloadDir.complete(value);
    }).catchError((e) {
      downloadDir.completeError(e);
    });
  }
  static AppPath? _instance;
  Completer<Directory> dataDir = Completer();
  Completer<Directory> downloadDir = Completer();
  Completer<Directory> tempDir = Completer();
  late String appDirPath;

  String get executableExtension => Platform.isWindows ? ".exe" : "";

  String get executableDirPath {
    final currentExecutablePath = Platform.resolvedExecutable;
    return dirname(currentExecutablePath);
  }

  String get desktopInstallRoot =>
      Platform.isMacOS ? dirname(executableDirPath) : executableDirPath;

  String get desktopArchitecture => switch (Abi.current()) {
        Abi.linuxX64 || Abi.windowsX64 || Abi.macosX64 => 'x86_64',
        Abi.linuxArm64 || Abi.windowsArm64 || Abi.macosArm64 => 'arm64',
        _ => throw UnsupportedError(
            'FlClashM has no runtime layout for `${Abi.current()}`.',
          ),
      };

  String get _desktopRuntimeTarget => switch (Platform.operatingSystem) {
        'linux' || 'windows' || 'macos' => Platform.operatingSystem,
        _ => throw UnsupportedError(
            'FlClashM has no desktop runtime for `${Platform.operatingSystem}`.',
          ),
      };

  String _desktopArtifactPath(String artifact) =>
      '${ProductInstallLayout.artifactPath(
        installRoot: desktopInstallRoot,
        target: _desktopRuntimeTarget,
        architecture: desktopArchitecture,
        artifact: artifact,
      )}$executableExtension';

  String get corePath =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS
          ? _desktopArtifactPath(ProductInstallLayout.mihomoArtifact)
          : join(executableDirPath, "FlClashCore$executableExtension");

  String get corePendingPath => '$corePath.pending';

  /// Allow-list consumed by the Windows helper service; lives next to the
  /// helper exe so per-machine installs keep it admin-writable only.
  String get allowedCoreHashPath =>
      join(executableDirPath, "allowed_core.sha256");

  String get helperPath =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS
          ? _desktopArtifactPath(ProductInstallLayout.helperArtifact)
          : join(executableDirPath, "$appHelperService$executableExtension");

  Future<String> get downloadDirPath async {
    final directory = await downloadDir.future;
    return directory.path;
  }

  Future<String> get homeDirPath async {
    final directory = await dataDir.future;
    return directory.path;
  }

  Future<String> get lockFilePath async {
    final directory = await dataDir.future;
    return join(directory.path, "FlClashM.lock");
  }

  Future<String> get sharedPreferencesPath async {
    final directory = await dataDir.future;
    return join(directory.path, "shared_preferences.json");
  }

  Future<String> get profilesPath async {
    final directory = await dataDir.future;
    return join(directory.path, profilesDirectoryName);
  }

  Future<String> getProfilePath(String id) async {
    final directory = await profilesPath;
    return join(directory, "$id.yaml");
  }

  Future<String> getProvidersDirPath(String id) async {
    final directory = await profilesPath;
    return join(
      directory,
      "providers",
      id,
    );
  }

  Future<String> getProvidersFilePath(
    String id,
    String type,
    String url,
  ) async {
    final directory = await profilesPath;
    return join(
      directory,
      "providers",
      id,
      type,
      url.toMd5(),
    );
  }

  Future<String> get tempPath async {
    final directory = await tempDir.future;
    return directory.path;
  }
}

final appPath = AppPath();
