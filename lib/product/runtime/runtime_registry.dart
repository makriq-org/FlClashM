import 'package:flutter/foundation.dart';

import 'engine_adapter.dart';
import 'mihomo_engine_adapter.dart';
import 'runtime_types.dart';

typedef EngineAdapterFactory = EngineAdapter Function();

EngineAdapter _buildMihomoEngineAdapter() => const MihomoEngineAdapter();

@immutable
class EngineRuntimeRegistration {
  const EngineRuntimeRegistration({
    required this.descriptor,
    required this.availability,
    this.adapterFactory,
  });

  final RuntimeDescriptor descriptor;
  final RuntimeAvailability availability;
  final EngineAdapterFactory? adapterFactory;
}

enum HelperAttachment {
  alongsideEngine,
}

@immutable
class HelperRuntimeRegistration {
  const HelperRuntimeRegistration({
    required this.descriptor,
    required this.availability,
    required this.attachment,
    required this.supportedEngines,
  });

  final RuntimeDescriptor descriptor;
  final RuntimeAvailability availability;
  final HelperAttachment attachment;
  final Set<RuntimeId> supportedEngines;
}

@immutable
class ResolvedEngineRuntime {
  const ResolvedEngineRuntime({
    required this.registration,
    required this.adapter,
  });

  final EngineRuntimeRegistration registration;
  final EngineAdapter adapter;
}

@immutable
class ResolvedRuntimeSelection {
  const ResolvedRuntimeSelection({
    required this.selection,
    required this.engine,
    required this.helpers,
  });

  final RuntimeSelection selection;
  final ResolvedEngineRuntime engine;
  final List<HelperRuntimeRegistration> helpers;
}

class RuntimeRegistry {
  RuntimeRegistry({
    required this.defaultSelection,
    required List<EngineRuntimeRegistration> engines,
    List<HelperRuntimeRegistration> helpers = const [],
  })  : _engines = _buildEngineMap(engines),
        _helpers = _buildHelperMap(helpers) {
    _validateRegistryTopology();
  }

  factory RuntimeRegistry.flClashM() => RuntimeRegistry(
        defaultSelection: const RuntimeSelection.mihomo(),
        engines: [
          const EngineRuntimeRegistration(
            descriptor: RuntimeDescriptor(
              id: RuntimeId.mihomo,
              role: RuntimeRole.engine,
              capabilities: {
                RuntimeCapability.tun,
                RuntimeCapability.coldStartPersistence,
                RuntimeCapability.pendingBinarySwap,
              },
            ),
            availability: RuntimeAvailability.supported(
              updatePath:
                  'Bundled Android core is built by setup.dart into libclash/android.',
              rollbackPath:
                  'Fallback stays on the bundled mihomo path and current cold-start snapshot.',
            ),
            adapterFactory: _buildMihomoEngineAdapter,
          ),
          const EngineRuntimeRegistration(
            descriptor: RuntimeDescriptor(
              id: RuntimeId.olcrtc,
              role: RuntimeRole.engine,
              capabilities: {
                RuntimeCapability.localSocks5Listener,
                RuntimeCapability.vpnProtect,
                RuntimeCapability.externalServerDependency,
              },
            ),
            availability: RuntimeAvailability.unsupported(
              reason:
                  'olcrtc Android packaging, gomobile bridge, and client-side room/key compilation are not integrated.',
              updatePath:
                  'Ship a pinned Android AAR plus Dart/Kotlin bridge for Start/Stop/SetProtector before enabling selection.',
              rollbackPath:
                  'Keep olcrtc unavailable in the registry and fall back to mihomo until binary, config, and migration paths are versioned.',
            ),
          ),
          const EngineRuntimeRegistration(
            descriptor: RuntimeDescriptor(
              id: RuntimeId.naiveproxy,
              role: RuntimeRole.engine,
              capabilities: {
                RuntimeCapability.localSocks5Listener,
                RuntimeCapability.externalServerDependency,
              },
            ),
            availability: RuntimeAvailability.unsupported(
              reason:
                  'naiveproxy binary packaging, config.json generation, and Android SOCKS-to-VPN orchestration are not integrated.',
              updatePath:
                  'Ship pinned release tags only, add config generation, and bridge the local SOCKS listener into Android VPN policy.',
              rollbackPath:
                  'Disable naiveproxy selection and return to mihomo if the packaged binary or bridge regresses.',
            ),
          ),
        ],
        helpers: [
          const HelperRuntimeRegistration(
            descriptor: RuntimeDescriptor(
              id: RuntimeId.byedpi,
              role: RuntimeRole.helper,
              capabilities: {
                RuntimeCapability.localSocks5Listener,
                RuntimeCapability.transparentProxy,
              },
            ),
            availability: RuntimeAvailability.unsupported(
              reason:
                  'byedpi helper supervision, lifecycle hooks, and Android routing policy are not integrated.',
              updatePath:
                  'Add an explicit helper supervisor and attachment contract to an engine before enabling byedpi.',
              rollbackPath:
                  'Detach byedpi from the registry and keep traffic on the client-controlled VPN path.',
            ),
            attachment: HelperAttachment.alongsideEngine,
            supportedEngines: {
              RuntimeId.mihomo,
              RuntimeId.olcrtc,
              RuntimeId.naiveproxy,
            },
          ),
        ],
      );

  final RuntimeSelection defaultSelection;
  final Map<RuntimeId, EngineRuntimeRegistration> _engines;
  final Map<RuntimeId, HelperRuntimeRegistration> _helpers;

  static Map<RuntimeId, EngineRuntimeRegistration> _buildEngineMap(
    List<EngineRuntimeRegistration> engines,
  ) {
    final registrations = <RuntimeId, EngineRuntimeRegistration>{};
    for (final engine in engines) {
      final runtimeId = engine.descriptor.id;
      if (engine.descriptor.role != RuntimeRole.engine) {
        throw ArgumentError(
          'Runtime ${runtimeId.label} must be registered with engine role.',
        );
      }
      if (registrations.containsKey(runtimeId)) {
        throw ArgumentError(
          'Engine ${runtimeId.label} is registered more than once.',
        );
      }
      registrations[runtimeId] = engine;
    }
    return registrations;
  }

  static Map<RuntimeId, HelperRuntimeRegistration> _buildHelperMap(
    List<HelperRuntimeRegistration> helpers,
  ) {
    final registrations = <RuntimeId, HelperRuntimeRegistration>{};
    for (final helper in helpers) {
      final runtimeId = helper.descriptor.id;
      if (helper.descriptor.role != RuntimeRole.helper) {
        throw ArgumentError(
          'Runtime ${runtimeId.label} must be registered with helper role.',
        );
      }
      if (registrations.containsKey(runtimeId)) {
        throw ArgumentError(
          'Helper ${runtimeId.label} is registered more than once.',
        );
      }
      registrations[runtimeId] = helper;
    }
    return registrations;
  }

  List<RuntimeDescriptor> get descriptors => [
        ..._engines.values.map((engine) => engine.descriptor),
        ..._helpers.values.map((helper) => helper.descriptor),
      ];

  void _validateRegistryTopology() {
    for (final helper in _helpers.values) {
      final helperId = helper.descriptor.id;
      if (_engines.containsKey(helperId)) {
        throw ArgumentError(
          'Runtime ${helperId.label} cannot be registered as both engine and helper.',
        );
      }

      for (final engineId in helper.supportedEngines) {
        if (!_engines.containsKey(engineId)) {
          throw ArgumentError(
            'Helper ${helperId.label} references unknown engine ${engineId.label}.',
          );
        }
      }
    }
  }

  ResolvedRuntimeSelection resolveSelection([RuntimeSelection? selection]) {
    final requestedSelection = selection ?? defaultSelection;
    _validateHelperSelection(requestedSelection.helpers);

    final engineRegistration = _engines[requestedSelection.engine];
    if (engineRegistration == null) {
      throw UnsupportedRuntimeSelectionException(
        'Engine ${requestedSelection.engine.label} is not registered.',
      );
    }
    if (!engineRegistration.availability.isSupported) {
      throw UnsupportedRuntimeSelectionException(
        _buildUnsupportedMessage(
          runtimeId: requestedSelection.engine,
          availability: engineRegistration.availability,
        ),
      );
    }

    final adapterFactory = engineRegistration.adapterFactory;
    if (adapterFactory == null) {
      throw UnsupportedRuntimeSelectionException(
        'Engine ${requestedSelection.engine.label} is registered without an adapter factory.',
      );
    }

    final resolvedHelpers = <HelperRuntimeRegistration>[];
    for (final helperId in requestedSelection.helpers) {
      final helperRegistration = _helpers[helperId];
      if (helperRegistration == null) {
        throw UnsupportedRuntimeSelectionException(
          'Helper ${helperId.label} is not registered.',
        );
      }
      if (!helperRegistration.availability.isSupported) {
        throw UnsupportedRuntimeSelectionException(
          _buildUnsupportedMessage(
            runtimeId: helperId,
            availability: helperRegistration.availability,
          ),
        );
      }
      if (!helperRegistration.supportedEngines
          .contains(requestedSelection.engine)) {
        throw UnsupportedRuntimeSelectionException(
          'Helper ${helperId.label} does not support engine ${requestedSelection.engine.label}.',
        );
      }
      resolvedHelpers.add(helperRegistration);
    }

    return ResolvedRuntimeSelection(
      selection: requestedSelection,
      engine: ResolvedEngineRuntime(
        registration: engineRegistration,
        adapter: adapterFactory(),
      ),
      helpers: resolvedHelpers,
    );
  }

  void _validateHelperSelection(List<RuntimeId> helperIds) {
    if (helperIds.toSet().length != helperIds.length) {
      throw const UnsupportedRuntimeSelectionException(
        'Helper runtime selection contains duplicates.',
      );
    }

    for (final helperId in helperIds) {
      if (_engines.containsKey(helperId)) {
        throw UnsupportedRuntimeSelectionException(
          'Runtime ${helperId.label} is registered as an engine and cannot be selected as a helper.',
        );
      }
    }
  }

  String _buildUnsupportedMessage({
    required RuntimeId runtimeId,
    required RuntimeAvailability availability,
  }) =>
      '${runtimeId.label} is not available: ${availability.reason} '
      'Update path: ${availability.updatePath} '
      'Rollback path: ${availability.rollbackPath}';
}
