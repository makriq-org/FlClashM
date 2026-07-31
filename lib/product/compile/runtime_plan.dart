import 'package:flclashx/models/models.dart';
import 'package:flutter/foundation.dart';

import '../runtime/built_in_proxy_types.dart';
import '../runtime/runtime_types.dart';

@immutable
class CompiledProfileMetadata {
  const CompiledProfileMetadata({
    required this.externalController,
    this.secret = '',
    required this.tcpConcurrent,
    required this.unifiedDelay,
    required this.logLevel,
    required this.keepAliveInterval,
    required this.groupDescriptions,
  });

  final String externalController;
  final String secret;
  final bool tcpConcurrent;
  final bool unifiedDelay;
  final String logLevel;
  final int keepAliveInterval;
  final Map<String, String> groupDescriptions;
}

@immutable
class CompiledProfilePatch {
  const CompiledProfilePatch({
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
    this.files = const {},
    this.builtInProxyNodes = const [],
    required this.metadata,
    this.profileAccessControl,
    this.diagnostics = const [],
  });

  const RuntimePlan.empty({
    required this.selectedMap,
    required this.testUrl,
    this.runtime = const RuntimeSelection.mihomo(),
    this.files = const {},
    this.builtInProxyNodes = const [],
    this.profileAccessControl,
    this.diagnostics = const [],
  })  : config = const <String, dynamic>{},
        metadata = null;

  final Map<String, dynamic> config;
  final Map<String, String> selectedMap;
  final String testUrl;
  final RuntimeSelection runtime;
  final Map<String, String> files;
  final List<BuiltInProxyNodePlan> builtInProxyNodes;
  final CompiledProfileMetadata? metadata;
  final AccessControl? profileAccessControl;
  final List<String> diagnostics;

  SetupParams toSetupParams() => SetupParams(
        config: config,
        selectedMap: selectedMap,
        testUrl: testUrl,
      );
}
