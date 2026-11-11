import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef ExternalNodeScope = ({
  String? instance,
  int? generation,
  String? profile,
  bool running,
});
typedef ExternalNodeStamp = (ExternalNodeScope?, ExternalNodeStatus?);

/// A presentation epoch changes with identity, sleep or startup readiness. A real
/// failure of an awake process must still accept its delay-test result.
class ExternalNodeStatus {
  ExternalNodeStatus(
    this.id, {
    required this.sleeping,
    required this.awake,
    required this.starting,
  });
  final String id;
  final bool sleeping;
  final bool awake;
  final bool starting;
}

class ExternalNodes {
  const ExternalNodes({this.scope, this.nodes = const {}});
  final ExternalNodeScope? scope;
  final Map<String, ExternalNodeStatus> nodes;

  bool sleeping(String name) => nodes[name]?.sleeping == true;
  ExternalNodeStamp stamp(String name) => (scope, nodes[name]);
  bool accepts(String name, ExternalNodeStamp stamp) =>
      !sleeping(name) && this.stamp(name) == stamp;
}

final externalNodesProvider =
    NotifierProvider<ExternalNodesProjection, ExternalNodes>(
      ExternalNodesProjection.new,
    );

/// Read-only projection of Go state; never starts or stops a node.
class ExternalNodesProjection extends Notifier<ExternalNodes> {
  @override
  ExternalNodes build() => const ExternalNodes();

  void project({
    required Map runtime,
    required String? profileId,
    required String? appliedProfileId,
    required int viewGeneration,
  }) {
    final scope = (
      instance: runtime['instanceId'] as String?,
      generation: (runtime['appliedGeneration'] as num?)?.toInt(),
      profile: profileId,
      running: runtime['appliedRunning'] == true,
    );
    final coherent =
        profileId != null &&
        profileId == appliedProfileId &&
        scope.generation == viewGeneration &&
        runtime['nodesGeneration'] == scope.generation;
    final nodes = <String, ExternalNodeStatus>{};
    if (coherent) {
      for (final raw in runtime['nodes'] as List? ?? const []) {
        if (raw is! Map) continue;
        final name = raw['name'];
        final id = raw['nodeId'];
        if (name is! String || name.isEmpty || id is! String) continue;
        final awake = raw['awake'] == true;
        final starting = raw['state'] == 'starting';
        final sleeping = raw['state'] == 'sleeping' && raw['awake'] == false;
        final old = state.scope == scope ? state.nodes[name] : null;
        nodes[name] =
            old != null &&
                old.id == id &&
                old.sleeping == sleeping &&
                old.awake == awake &&
                old.starting == starting
            ? old
            : ExternalNodeStatus(
                id,
                sleeping: sleeping,
                awake: awake,
                starting: starting,
              );
      }
    }
    if (state.scope == scope && mapEquals(state.nodes, nodes)) return;
    state = ExternalNodes(scope: scope, nodes: Map.unmodifiable(nodes));
  }
}
