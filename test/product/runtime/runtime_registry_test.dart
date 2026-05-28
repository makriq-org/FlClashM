import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/product_compile.dart';
import 'package:flclashx/product/runtime/product_runtime.dart';
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
      expect(resolved.helpers, isEmpty);
    });

    test('rejects unsupported olcrtc engine with guardrail details', () {
      expect(
        () => registry.resolveSelection(
          const RuntimeSelection(engine: RuntimeId.olcrtc),
        ),
        throwsA(
          isA<UnsupportedRuntimeSelectionException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('olcrtc is not available'),
              contains('Update path:'),
              contains('Rollback path:'),
            ),
          ),
        ),
      );
    });

    test('resolves naiveproxy as a supported engine', () {
      final resolved = registry.resolveSelection(
        const RuntimeSelection(engine: RuntimeId.naiveproxy),
      );

      expect(resolved.selection.engine, RuntimeId.naiveproxy);
      expect(resolved.engine.registration.availability.isSupported, isTrue);
      expect(
        resolved.engine.registration.descriptor.capabilities,
        contains(RuntimeCapability.pendingBinarySwap),
      );
    });

    test('rejects engine registrations in helper slot', () {
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
            contains('cannot be selected as a helper'),
          ),
        ),
      );
    });

    test('rejects unsupported byedpi helper selection', () {
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
            contains('byedpi is not available'),
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

    test('rejects helper registrations that reference unknown engines', () {
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
          ],
          helpers: [
            const HelperRuntimeRegistration(
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
              attachment: HelperAttachment.alongsideEngine,
              supportedEngines: {RuntimeId.naiveproxy},
            ),
          ],
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('references unknown engine'),
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
    required SetupParams setupParams,
    required CoreState state,
  }) async {}
}
