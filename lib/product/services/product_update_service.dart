typedef AsyncTaskRunner = Future<T?> Function<T>(
  Future<T> Function() task, {
  String? title,
});

typedef SkipAppUpdateRelease = Future<void> Function(String tagName);

/// Product-facing updater contract. A platform must explicitly provide an
/// installer instead of silently treating an unsupported handoff as success.
abstract interface class ProductUpdateService {
  Future<void> autoCheck({
    required bool enabled,
    required bool includePrerelease,
    required String skippedTagName,
    SkipAppUpdateRelease? onSkipRelease,
  });

  Future<void> manualCheck({
    required AsyncTaskRunner runTask,
    required bool includePrerelease,
    required String skippedTagName,
    SkipAppUpdateRelease? onSkipRelease,
    String? loadingTitle,
  });
}
