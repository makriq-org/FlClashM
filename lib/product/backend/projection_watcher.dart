/// Serial projections remember a backend only after it acknowledged visibility.
/// Failed delivery leaves it pending for the next snapshot refresh.
class HostVisibilityProjection {
  String? _instance;

  Future<void> synchronize(
    String? instance,
    Future<void> Function() send,
  ) async {
    if (instance == null || instance == _instance) return;
    await send();
    _instance = instance;
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
