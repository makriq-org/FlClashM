import 'raw_profile.dart';

typedef LoadRawProfileRevision = Future<RawProfile> Function();

/// Process-local cache for the immutable, evaluated profile revision.
///
/// Callers still stat the profile before every request. YAML parsing and script
/// evaluation are shared only when the complete revision key matches.
class LoadedProfileRepository {
  RawProfile? _cached;
  RawProfileRevision? _loadingRevision;
  Future<RawProfile>? _loading;

  Future<RawProfile> load(
    RawProfileRevision revision,
    LoadRawProfileRevision loader,
  ) async {
    final cached = _cached;
    if (cached?.revision == revision) return cached!;
    if (_loadingRevision == revision && _loading != null) return _loading!;

    final task = loader();
    _loadingRevision = revision;
    _loading = task;
    try {
      final loaded = await task;
      if (identical(_loading, task) && _loadingRevision == revision) {
        _cached = loaded;
      }
      return loaded;
    } finally {
      if (identical(_loading, task)) {
        _loading = null;
        _loadingRevision = null;
      }
    }
  }

  void clear() {
    _cached = null;
    _loading = null;
    _loadingRevision = null;
  }
}
