import 'package:flclashm/models/models.dart';
import 'package:flclashm/product/compile/product_compile.dart';
import 'package:flclashm/product/runtime/product_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RuntimeRegistry', () {
    final registry = RuntimeRegistry.flClashM(
      readAccessControl: () => const AccessControl(),
    );

    test('resolves bundled mihomo by default', () {
      final resolved = registry.resolveSelection();

      expect(resolved.selection, const RuntimeSelection.mihomo());
      expect(resolved.engine.registration.descriptor.id, RuntimeId.mihomo);
    });

    test('rejects unregistered olcrtc engine selection', () {
      expect(
        () => registry.resolveSelection(
          const RuntimeSelection(engine: RuntimeId.olcrtc),
        ),
        throwsA(
          isA<UnsupportedRuntimeSelectionException>().having(
            (error) => error.message,
            'message',
            contains('Engine olcrtc is not registered.'),
          ),
        ),
      );
    });

    test('rejects naiveproxy runtime selection in the product registry', () {
      expect(
        () => registry.resolveSelection(
          const RuntimeSelection(engine: RuntimeId.naiveproxy),
        ),
        throwsA(
          isA<UnsupportedRuntimeSelectionException>().having(
            (error) => error.message,
            'message',
            contains('Engine naiveproxy is not registered.'),
          ),
        ),
      );
    });

    test('rejects helper runtime selection in product registry', () {
      expect(
        () => registry.resolveSelection(
          const RuntimeSelection(
            engine: RuntimeId.mihomo,
            helpers: [RuntimeId.naiveproxy],
          ),
        ),
        throwsA(
          isA<UnsupportedRuntimeSelectionException>().having(
            (error) => error.message,
            'message',
            contains('Helper runtime selection is not used in FlClashM'),
          ),
        ),
      );
    });

    test('rejects byedpi helper selection in product registry', () {
      expect(
        () => registry.resolveSelection(
          const RuntimeSelection(
            engine: RuntimeId.mihomo,
            helpers: [RuntimeId.byedpi],
          ),
        ),
        throwsA(
          isA<UnsupportedRuntimeSelectionException>().having(
            (error) => error.message,
            'message',
            contains('Helper runtime selection is not used in FlClashM'),
          ),
        ),
      );
    });

    test('rejects duplicate engine registrations at construction time', () {
      expect(
        () => RuntimeRegistry(
          defaultSelection: const RuntimeSelection.mihomo(),
          engines: [
            const EngineRuntimeRegistration(
              descriptor: RuntimeDescriptor(
                id: RuntimeId.mihomo,
                role: RuntimeRole.engine,
                capabilities: {RuntimeCapability.tun},
              ),
              availability: RuntimeAvailability.supported(
                updatePath: 'bundled',
                rollbackPath: 'bundled',
              ),
              adapterFactory: _FakeEngineAdapter.new,
            ),
            const EngineRuntimeRegistration(
              descriptor: RuntimeDescriptor(
                id: RuntimeId.mihomo,
                role: RuntimeRole.engine,
                capabilities: {RuntimeCapability.tun},
              ),
              availability: RuntimeAvailability.supported(
                updatePath: 'bundled',
                rollbackPath: 'bundled',
              ),
              adapterFactory: _FakeEngineAdapter.new,
            ),
          ],
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('registered more than once'),
          ),
        ),
      );
    });

    test('rejects non-engine registrations at construction time', () {
      expect(
        () => RuntimeRegistry(
          defaultSelection: const RuntimeSelection.mihomo(),
          engines: [
            const EngineRuntimeRegistration(
              descriptor: RuntimeDescriptor(
                id: RuntimeId.mihomo,
                role: RuntimeRole.engine,
                capabilities: {RuntimeCapability.tun},
              ),
              availability: RuntimeAvailability.supported(
                updatePath: 'bundled',
                rollbackPath: 'bundled',
              ),
              adapterFactory: _FakeEngineAdapter.new,
            ),
            const EngineRuntimeRegistration(
              descriptor: RuntimeDescriptor(
                id: RuntimeId.byedpi,
                role: RuntimeRole.helper,
                capabilities: {RuntimeCapability.localSocks5Listener},
              ),
              availability: RuntimeAvailability.unsupported(
                reason: 'disabled',
                updatePath: 'supervisor',
                rollbackPath: 'detach',
              ),
              adapterFactory: _FakeEngineAdapter.new,
            ),
          ],
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('must be registered with engine role'),
          ),
        ),
      );
    });
  });
}

class _FakeEngineAdapter implements EngineAdapter {
  @override
  Future<void> applyPendingUpdate() async {}

  @override
  Future<void> prepareForRestart() async {}

  @override
  Future<bool> isInitialized() async => true;

  @override
  Future<void> initialize({
    required InitParams initParams,
    required CoreState state,
  }) async {}

  @override
  Future<String> setupRuntimePlan(RuntimePlan runtimePlan) async => '';

  @override
  Future<String> updateRuntimeConfig(UpdateParams updateParams) async => '';

  @override
  Future<bool> start({String? notificationTitle}) async => true;

  @override
  Future<void> stop() async {}

  @override
  Future<DateTime?> readStartTime() async => null;

  @override
  Future<void> persistColdStart({
    required InitParams initParams,
    required RuntimePlan runtimePlan,
    required CoreState state,
  }) async {}
}
