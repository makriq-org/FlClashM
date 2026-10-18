import 'dart:async';

/// Loading is UI state; the backend owns the actual subscription operation.
/// Repeated taps share its wait and every completion clears the local spinner.
class ProfileRefreshes {
  final _pending = <String, Future<void>>{};

  Future<void> run(
    String id, {
    required Future<void> Function() refresh,
    required void Function({required bool loading}) setLoading,
  }) {
    final pending = _pending[id];
    if (pending != null) return pending;
    final result = Completer<void>();
    _pending[id] = result.future;
    unawaited(
      Future<void>(() async {
        try {
          setLoading(loading: true);
          await refresh();
          result.complete();
        } catch (error, stack) {
          result.completeError(error, stack);
        } finally {
          unawaited(_pending.remove(id));
          setLoading(loading: false);
        }
      }),
    );
    return result.future;
  }
}
