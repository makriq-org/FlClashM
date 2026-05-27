import 'package:flclashx/models/models.dart';
import 'package:flutter/foundation.dart';

import '../runtime/runtime_types.dart';

@immutable
class CompiledProfileMetadata {
  const CompiledProfileMetadata({
    required this.externalController,
    required this.tcpConcurrent,
    required this.unifiedDelay,
    required this.logLevel,
    required this.keepAliveInterval,
    required this.groupDescriptions,
  });

  final String externalController;
  final bool tcpConcurrent;
  final bool unifiedDelay;
  final String logLevel;
  final int keepAliveInterval;
  final Map<String, String> groupDescriptions;
}

@immutable
class ResolvedProfilePatch {
  const ResolvedProfilePatch({
    required this.patchConfig,
    required this.metadata,
  });

  final ClashConfig patchConfig;
  final CompiledProfileMetadata? metadata;
}

@immutable
class RuntimePlan {
  const RuntimePlan({
    required this.config,
    required this.selectedMap,
    required this.testUrl,
    this.runtime = const RuntimeSelection.mihomo(),
    required this.metadata,
  });

  const RuntimePlan.empty({
    required this.selectedMap,
    required this.testUrl,
    this.runtime = const RuntimeSelection.mihomo(),
  })  : config = const <String, dynamic>{},
        metadata = null;

  final Map<String, dynamic> config;
  final Map<String, String> selectedMap;
  final String testUrl;
  final RuntimeSelection runtime;
  final CompiledProfileMetadata? metadata;

  SetupParams toSetupParams() => SetupParams(
        config: config,
        selectedMap: selectedMap,
        testUrl: testUrl,
      );
}
