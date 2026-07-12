import 'package:flutter/foundation.dart';

import 'engine_adapter.dart';
import 'mihomo_engine_adapter.dart';
import 'runtime_types.dart';

typedef EngineAdapterFactory = EngineAdapter Function();

EngineAdapter _buildMihomoEngineAdapter(
  ReadAccessControlCallback readAccessControl,
) =>
    MihomoEngineAdapter(
      readAccessControl: readAccessControl,
    );

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
  });

  final RuntimeSelection selection;
  final ResolvedEngineRuntime engine;
}

class RuntimeRegistry {
  RuntimeRegistry({
    required this.defaultSelection,
    required List<EngineRuntimeRegistration> engines,
  }) : _engines = _buildEngineMap(engines);

  factory RuntimeRegistry.flClashM({
    required ReadAccessControlCallback readAccessControl,
  }) =>
      RuntimeRegistry(
        defaultSelection: const RuntimeSelection.mihomo(),
        engines: [
          EngineRuntimeRegistration(
            descriptor: const RuntimeDescriptor(
              id: RuntimeId.mihomo,
              role: RuntimeRole.engine,
              capabilities: {
                RuntimeCapability.tun,
                RuntimeCapability.coldStartPersistence,
                RuntimeCapability.pendingBinarySwap,
              },
            ),
            availability: const RuntimeAvailability.supported(
              updatePath:
                  'Bundled Android core is built by setup.dart into libclash/android.',
              rollbackPath:
                  'Fallback stays on the bundled mihomo path and current cold-start snapshot.',
            ),
            adapterFactory: () => _buildMihomoEngineAdapter(
              readAccessControl,
            ),
          ),
        ],
      );

  final RuntimeSelection defaultSelection;
  final Map<RuntimeId, EngineRuntimeRegistration> _engines;

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

  List<RuntimeDescriptor> get descriptors =>
      _engines.values.map((engine) => engine.descriptor).toList();

  ResolvedRuntimeSelection resolveSelection([RuntimeSelection? selection]) {
    final requestedSelection = selection ?? defaultSelection;
    if (requestedSelection.helpers.isNotEmpty) {
      throw const UnsupportedRuntimeSelectionException(
        'Helper runtime selection is not used in FlClashM. '
        'Built-in transports must be declared as proxy nodes inside the profile, not as runtime helpers.',
      );
    }

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

    return ResolvedRuntimeSelection(
      selection: requestedSelection,
      engine: ResolvedEngineRuntime(
        registration: engineRegistration,
        adapter: adapterFactory(),
      ),
    );
  }

  String _buildUnsupportedMessage({
    required RuntimeId runtimeId,
    required RuntimeAvailability availability,
  }) =>
      '${runtimeId.label} is not available: ${availability.reason} '
      'Update path: ${availability.updatePath} '
      'Rollback path: ${availability.rollbackPath}';
}
