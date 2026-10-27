import 'dart:async';

/// Delivers visibility independently of snapshot projection, with bounded backoff.
class HostVisibilityProjection {
  HostVisibilityProjection({this.onError});

  final void Function(Object error)? onError;
  String? _instance;
  String? _desired;
  late Future<void> Function() _send;
  Timer? _retry;
  var _running = false;
  var _disposed = false;
  var _failures = 0;

  void synchronize(String? instance, Future<void> Function() send) {
    if (_disposed) return;
    if (instance != _desired) {
      _desired = instance;
      _instance = null;
      _failures = 0;
      _retry?.cancel();
      _retry = null;
    }
    _send = send;
    if (instance != null && instance != _instance && _retry == null) {
      unawaited(_attempt());
    }
  }

  Future<void> _attempt() async {
    if (_disposed || _running || _desired == null) return;
    final instance = _desired;
    final send = _send;
    _running = true;
    try {
      await send();
      if (!_disposed && _desired == instance) {
        _instance = instance;
        _failures = 0;
      }
    } catch (error) {
      if (!_disposed && _desired == instance) {
        onError?.call(error);
        final seconds = 1 << _failures.clamp(0, 5);
        _failures++;
        _retry = Timer(Duration(seconds: seconds), () {
          _retry = null;
          unawaited(_attempt());
        });
      }
    } finally {
      _running = false;
      if (!_disposed && _desired != instance && _desired != null) {
        unawaited(_attempt());
      }
    }
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
  }
}

/// What a new backend projection invalidates in UI-only caches.
enum ProjectionChange {
  none,

  /// The selected or applied profile changed: per-profile delays, logs,
  /// requests and scroll caches describe another profile now.
  profile,

  /// A new runtime plan was applied to the same profile: groups may differ.
  generation,
}

/// Compares consecutive projections of Go snapshots. The first observation
/// only records the baseline.
class ProjectionWatcher {
  bool _seen = false;
  String? _profileId;
  String? _appliedProfileId;
  int? _generation;

  ProjectionChange observe({
    required String? profileId,
    required String? appliedProfileId,
    required int? generation,
  }) {
    // A stopped runtime may report no applied profile; that is not a switch.
    final applied = appliedProfileId == null || appliedProfileId.isEmpty
        ? _appliedProfileId
        : appliedProfileId;
    final seen = _seen;
    final profileChanged =
        profileId != _profileId || applied != _appliedProfileId;
    final generationChanged = generation != _generation;
    _seen = true;
    _profileId = profileId;
    _appliedProfileId = applied;
    _generation = generation;
    if (!seen) return ProjectionChange.none;
    if (profileChanged) return ProjectionChange.profile;
    if (generationChanged) return ProjectionChange.generation;
    return ProjectionChange.none;
  }
}
