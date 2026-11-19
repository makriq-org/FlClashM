import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../common/common.dart';
import 'app_update_http.dart';
import 'app_update_identity.dart';
import 'app_update_install_journal.dart';
import 'app_update_release.dart';

enum AppUpdatePhase { prompt, downloading, verifying, ready, installing }

enum AppUpdateFailureKind { download, verify, install }

@immutable
class AppUpdateFailure {
  const AppUpdateFailure(this.kind, [this.detail]);

  final AppUpdateFailureKind kind;
  final String? detail;
}

/// Проверенный APK, готовый к передаче установщику.
@immutable
class AppUpdatePrepared {
  const AppUpdatePrepared({
    required this.path,
    required this.sha256,
    required this.identity,
  });

  final String path;
  final String sha256;
  final AppUpdatePackageIdentity identity;
}

/// Платформенные шаги загрузки, проверки и передачи установщику. Отделены от
/// окна: состояние ведёт [AppUpdateSession], а окно только показывает его.
abstract interface class AppUpdateInstaller {
  Future<List<String>> readSupportedAbis();

  Future<String> getUpdateDirectoryPath();

  Future<String?> readRemoteText(String url);

  Future<String> downloadReleaseAsset(
    ReleaseAsset asset,
    String targetPath, {
    required String expectedSha256,
    void Function(int received, int total)? onReceiveProgress,
    AppUpdateDownloadCancellation? cancellation,
  });

  Future<AppUpdatePackageIdentity?> inspectInstalledPackage();

  Future<AppUpdatePackageIdentity?> inspectPackage(String path);

  Future<void> prepareInstallHandoff();

  Future<bool> installPackage(String path);
}

typedef AppUpdateFileHasher = Future<String> Function(File file);

/// Одна попытка обновления: загрузка (или готовый APK из прошлой попытки),
/// проверка и явная установка. Окно не закрывается само, а APK остаётся на
/// диске после передачи установщику, поэтому отменённая установка
/// повторяется без загрузки и с повторной проверкой.
class AppUpdateSession extends ChangeNotifier {
  AppUpdateSession({
    required this.release,
    required this.installer,
    required this.journal,
    this.fileHasher = computeFileSha256,
    this.requiredUpdate = false,
  });

  final AppRelease release;
  final AppUpdateInstaller installer;
  final AppUpdateInstallJournal journal;
  final AppUpdateFileHasher fileHasher;
  final bool requiredUpdate;

  AppUpdatePhase _phase = AppUpdatePhase.prompt;
  AndroidReleaseAsset? _asset;
  AppUpdatePrepared? _prepared;
  AppUpdateFailure? _failure;
  String? _apkPath;
  bool _handedOff = false;
  int _received = 0;
  int _total = 0;
  Duration _elapsed = Duration.zero;
  int _generation = 0;
  bool _disposed = false;
  AppUpdateDownloadCancellation? _cancellation;
  Stopwatch? _stopwatch;

  AppUpdatePhase get phase => _phase;
  AndroidReleaseAsset? get asset => _asset;
  AppUpdatePrepared? get prepared => _prepared;
  AppUpdateFailure? get failure => _failure;

  /// Установщик уже открыт; файл остаётся для повтора.
  bool get handedOff => _handedOff;

  int get received => _received;
  int get total => _total;
  Duration get elapsed => _elapsed;

  bool get isBusy =>
      _phase == AppUpdatePhase.downloading ||
      _phase == AppUpdatePhase.verifying ||
      _phase == AppUpdatePhase.installing;

  bool get canInstall => _phase == AppUpdatePhase.ready && _prepared != null;

  /// Загрузка заново разрешена, когда проверенного файла ещё нет.
  bool get canDownload => _prepared == null && !isBusy;

  Future<void> download() async {
    if (_disposed || isBusy) {
      return;
    }
    final generation = ++_generation;
    _failure = null;
    _handedOff = false;
    _prepared = null;
    _received = 0;
    _total = 0;
    _elapsed = Duration.zero;
    _stopwatch = Stopwatch()..start();
    _setPhase(AppUpdatePhase.downloading);

    final cancellation = AppUpdateDownloadCancellation();
    _cancellation = cancellation;
    Directory? attemptDirectory;
    try {
      final supportedAbis = await installer.readSupportedAbis();
      final asset = selectAndroidReleaseAsset(
        release,
        supportedAbis: supportedAbis,
      );
      if (asset == null) {
        throw StateError(
          'No compatible Android APK asset was found for '
          '${supportedAbis.join(', ')}.',
        );
      }
      _asset = asset;
      if (asset.apkAsset.size > appUpdateMaxApkBytes) {
        throw StateError('Android APK is larger than the updater accepts.');
      }
      final expectedSha256 = await _resolveExpectedSha256(asset);
      final expectedVersionCode = expectedAppUpdateVersionCode(release, asset);
      final updateDirectoryPath = await installer.getUpdateDirectoryPath();
      _ensureCurrent(generation);
      final fileName = appUpdateApkFileName(asset.apkAsset.name);
      if (fileName == null) {
        throw StateError('Unsafe APK asset name `${asset.apkAsset.name}`.');
      }
      final apkPath = path.join(updateDirectoryPath, fileName);
      _apkPath = apkPath;

      final cached = await _reuseCached(
        File(apkPath),
        expectedSha256: expectedSha256,
        expectedVersionCode: expectedVersionCode,
        generation: generation,
      );
      if (cached != null) {
        _prepared = cached;
        _setPhase(AppUpdatePhase.ready);
        return;
      }

      await Directory(updateDirectoryPath).create(recursive: true);
      _ensureCurrent(generation);
      attemptDirectory = await Directory(updateDirectoryPath)
          .createTemp('.download-');
      _ensureCurrent(generation);
      final partial = File(path.join(attemptDirectory.path, 'update.part'));
      final actualSha256 = await installer.downloadReleaseAsset(
        asset.apkAsset,
        partial.path,
        expectedSha256: expectedSha256,
        onReceiveProgress: (received, total) {
          if (generation != _generation || _disposed) {
            return;
          }
          _received = received;
          _total = total;
          _elapsed = _stopwatch?.elapsed ?? Duration.zero;
          notifyListeners();
        },
        cancellation: cancellation,
      );
      _ensureCurrent(generation);
      if (actualSha256 != expectedSha256) {
        throw StateError(
          'SHA256 verification failed for `${asset.apkAsset.name}`.',
        );
      }
      final apkFile = File(apkPath);
      if (apkFile.existsSync()) {
        apkFile.deleteSync();
      }
      partial.renameSync(apkPath);

      _setPhase(AppUpdatePhase.verifying);
      final prepared = await _verifyFile(
        apkFile,
        expectedSha256: expectedSha256,
        expectedVersionCode: expectedVersionCode,
      );
      _ensureCurrent(generation);
      _prepared = prepared;
      _setPhase(AppUpdatePhase.ready);
    } on AppUpdateDownloadCancelledException {
      if (generation == _generation) {
        _setPhase(AppUpdatePhase.prompt);
      }
    } on _Superseded {
      return;
    } on AppUpdateIdentityException catch (error) {
      if (generation != _generation) {
        return;
      }
      _deleteQuietly(_fileAt(_apkPath));
      _fail(AppUpdateFailureKind.verify, '$error');
    } catch (error) {
      if (generation != _generation || cancellation.isCancelled) {
        return;
      }
      final kind = _phase == AppUpdatePhase.verifying
          ? AppUpdateFailureKind.verify
          : AppUpdateFailureKind.download;
      _fail(kind, '$error');
    } finally {
      try {
        attemptDirectory?.deleteSync(recursive: true);
      } on FileSystemException catch (error) {
        commonPrint.log('Could not remove temporary app update: $error');
      }
      if (identical(_cancellation, cancellation)) {
        _cancellation = null;
      }
    }
  }

  Future<void> install() async {
    final prepared = _prepared;
    if (_disposed || isBusy || prepared == null) {
      return;
    }
    final generation = ++_generation;
    _failure = null;
    _handedOff = false;
    _setPhase(AppUpdatePhase.installing);
    final file = File(prepared.path);
    try {
      if (!file.existsSync()) {
        throw const AppUpdateIdentityException(
          AppUpdateIdentityFailure.candidateUnavailable,
          'missing file',
        );
      }
      final actualSha256 = await fileHasher(file);
      _ensureCurrent(generation);
      if (actualSha256 != prepared.sha256) {
        throw const AppUpdateIdentityException(
          AppUpdateIdentityFailure.candidateUnavailable,
          'checksum changed',
        );
      }
      final candidate = await installer.inspectPackage(file.path);
      final installed = await installer.inspectInstalledPackage();
      _ensureCurrent(generation);
      checkAppUpdateIdentity(
        installed: installed,
        candidate: candidate,
        expectedVersionCode: _expectedVersionCode,
      );
      await journal.recordPrepared(candidate!.versionCode);
      _ensureCurrent(generation);

      // Остановка runtime нужна только перед передачей установщику: загрузка
      // и проверка VPN не трогают.
      try {
        await installer.prepareInstallHandoff();
      } catch (error) {
        commonPrint.log('Runtime stop before installer handoff failed: $error');
      }
      _ensureCurrent(generation);
      final opened = await installer.installPackage(file.path);
      _ensureCurrent(generation);
      if (!opened) {
        throw StateError('Unable to open the Android installer.');
      }
      // APK остаётся: отменённая установка повторяется без загрузки.
      _handedOff = true;
      _setPhase(AppUpdatePhase.ready);
    } on _Superseded {
      // Состоянием уже владеет более новая попытка.
    } on AppUpdateIdentityException catch (error) {
      if (generation != _generation) {
        return;
      }
      // Подменённый или испорченный файл оставлять нельзя.
      _deleteQuietly(file);
      _prepared = null;
      _fail(AppUpdateFailureKind.verify, '$error');
    } catch (error) {
      if (generation != _generation) {
        return;
      }
      // Установщик не открылся: файл проверен, повтор не требует загрузки.
      _failure = AppUpdateFailure(AppUpdateFailureKind.install, '$error');
      _setPhase(AppUpdatePhase.ready);
    }
  }

  /// Повтор после сбоя: открыть установщик ещё раз, если APK проверен, иначе
  /// скачать заново.
  Future<void> retry() async {
    final failure = _failure;
    if (failure?.kind == AppUpdateFailureKind.install && _prepared != null) {
      await install();
      return;
    }
    await download();
  }

  /// Отмена загрузки: файл недокачки удаляется, окно возвращается к описанию.
  void cancel() {
    if (_phase != AppUpdatePhase.downloading &&
        _phase != AppUpdatePhase.verifying) {
      return;
    }
    _generation++;
    _cancellation?.cancel();
    _cancellation = null;
    _prepared = null;
    _setPhase(AppUpdatePhase.prompt);
  }

  int? get _expectedVersionCode {
    final asset = _asset;
    if (asset == null) {
      return release.versionCode;
    }
    return expectedAppUpdateVersionCode(release, asset);
  }

  Future<String> _resolveExpectedSha256(AndroidReleaseAsset asset) async {
    final inlineDigest = asset.apkAsset.sha256Digest;
    if (inlineDigest != null) {
      return inlineDigest;
    }
    final checksumAsset = asset.checksumAsset;
    if (checksumAsset == null) {
      throw StateError(
        'No SHA256 checksum is available for `${asset.apkAsset.name}`.',
      );
    }
    final checksumContent = await installer.readRemoteText(
      checksumAsset.browserDownloadUrl,
    );
    final hash = parseSha256Content(
      checksumContent,
      assetName: asset.apkAsset.name,
    );
    if (hash == null) {
      throw StateError(
        'No SHA256 checksum is available for `${asset.apkAsset.name}`.',
      );
    }
    return hash;
  }

  /// Уже скачанный APK принимается только с тем же хешем и личностью: иначе он
  /// удаляется и загружается заново.
  Future<AppUpdatePrepared?> _reuseCached(
    File apkFile, {
    required String expectedSha256,
    required int? expectedVersionCode,
    required int generation,
  }) async {
    if (!apkFile.existsSync()) {
      return null;
    }
    _setPhase(AppUpdatePhase.verifying);
    try {
      final prepared = await _verifyFile(
        apkFile,
        expectedSha256: expectedSha256,
        expectedVersionCode: expectedVersionCode,
      );
      _ensureCurrent(generation);
      return prepared;
    } on AppUpdateIdentityException catch (error) {
      _ensureCurrent(generation);
      commonPrint.log('Discarded cached app update: $error');
      _deleteQuietly(apkFile);
      _setPhase(AppUpdatePhase.downloading);
      return null;
    }
  }

  Future<AppUpdatePrepared> _verifyFile(
    File file, {
    required String expectedSha256,
    required int? expectedVersionCode,
  }) async {
    final actualSha256 = await fileHasher(file);
    if (actualSha256 != expectedSha256) {
      throw const AppUpdateIdentityException(
        AppUpdateIdentityFailure.candidateUnavailable,
        'checksum mismatch',
      );
    }
    final candidate = await installer.inspectPackage(file.path);
    final installed = await installer.inspectInstalledPackage();
    checkAppUpdateIdentity(
      installed: installed,
      candidate: candidate,
      expectedVersionCode: expectedVersionCode,
    );
    return AppUpdatePrepared(
      path: file.path,
      sha256: actualSha256,
      identity: candidate!,
    );
  }

  void _fail(AppUpdateFailureKind kind, String detail) {
    _failure = AppUpdateFailure(kind, detail);
    _prepared = null;
    _received = 0;
    _total = 0;
    _elapsed = Duration.zero;
    _setPhase(AppUpdatePhase.prompt);
  }

  void _setPhase(AppUpdatePhase phase) {
    _phase = phase;
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _ensureCurrent(int generation) {
    if (generation != _generation || _disposed) {
      throw const _Superseded();
    }
  }

  static File? _fileAt(String? value) => value == null ? null : File(value);

  void _deleteQuietly(File? file) {
    final value = file;
    if (value == null) {
      return;
    }
    try {
      if (value.existsSync()) {
        value.deleteSync();
      }
    } on FileSystemException {
      return;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _cancellation?.cancel();
    _cancellation = null;
    super.dispose();
  }
}

final class _Superseded implements Exception {
  const _Superseded();
}

/// The downloaded APK is written under the update directory, so a release
/// asset name that names another path is refused. Signed manifests already
/// reject separators; the unsigned GitHub fallback does not.
String? appUpdateApkFileName(String name) {
  if (name.isEmpty || name.length > 255) {
    return null;
  }
  if (name == '.' || name == '..' || name.contains(RegExp(r'[/\\]'))) {
    return null;
  }
  return name;
}
