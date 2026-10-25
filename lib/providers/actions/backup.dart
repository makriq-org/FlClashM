part of '../action.dart';

typedef BackupDelivery = Future<bool> Function(String archivePath);

/// Returns the archive to restore, or null when the user backed out. A source
/// that downloads writes to [downloadPath], which is removed afterwards.
typedef BackupFetch = Future<String?> Function(String downloadPath);

@Riverpod(keepAlive: true)
class BackupAction extends _$BackupAction {
  @override
  void build() {}

  Future<bool> backup(BackupDelivery deliver) {
    return _withWorkDir((workDir) async {
      return deliver(await _createArchive(workDir));
    });
  }

  Future<bool> restore(RestoreOption option, BackupFetch fetch) {
    return _withWorkDir((workDir) async {
      final path = await fetch(join(workDir, 'download.zip'));
      if (path == null) return false;
      final token = await backendClient.upload(await File(path).readAsBytes());
      try {
        await backendClient.command('backup.restore', {
          'token': token,
          'onlyProfiles': option == RestoreOption.onlyProfiles,
          'replace':
              ref.read(appSettingProvider).restoreStrategy ==
              RestoreStrategy.override,
        });
      } finally {
        await backendClient.discardBlob(token);
      }
      return true;
    });
  }

  Future<bool> _withWorkDir(Future<bool> Function(String workDir) run) async {
    final workDir = Directory(join(await appPath.tempPath, 'backup$uniqueId'));
    await workDir.create(recursive: true);
    try {
      return await run(workDir.path);
    } finally {
      await workDir.safeDelete(recursive: true);
      await _discardLegacyStaging();
    }
  }

  /// Earlier versions staged restores in the home directory and never removed
  /// the downloaded archive.
  Future<void> _discardLegacyStaging() async {
    final homeDirPath = await appPath.homeDirPath;
    await File(join(homeDirPath, 'backup.zip')).safeDelete();
    await Directory(join(homeDirPath, 'restore')).safeDelete(recursive: true);
  }

  Future<String> _createArchive(String workDir) async {
    final receipt = await backendClient.command('backup.export');
    final blob = receipt['blob'] as Map;
    try {
      final path = join(workDir, 'backup.zip');
      await File(path).writeAsBytes(
        await backendClient.download(
          blob['token'] as String,
          (blob['size'] as num).toInt(),
        ),
      );
      return path;
    } finally {
      await backendClient.discardBlob(blob['token'] as String);
    }
  }
}
