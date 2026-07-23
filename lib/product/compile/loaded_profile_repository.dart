import 'raw_profile.dart';

typedef LoadRawProfileRevision = Future<RawProfile> Function();

/// Shares YAML parsing and script evaluation only for an exact profile
/// revision. A superseded in-flight load can finish for its caller, but can no
/// longer replace the current cache entry.
class LoadedProfileRepository {
  RawProfile? _cached;
  RawProfileRevision? _loadingRevision;
  Future<RawProfile>? _loading;

  Future<RawProfile> load(
    RawProfileRevision revision,
    LoadRawProfileRevision loader,
  ) async {
    final cached = _cached;
    if (cached?.revision == revision) {
      return cached!;
    }
    if (_loadingRevision == revision && _loading != null) {
      return _loading!;
    }

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
