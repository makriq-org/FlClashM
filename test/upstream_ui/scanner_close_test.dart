import 'dart:async';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/pages/scan.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../helpers/test_app.dart';

class _FakeScannerPlatform extends MobileScannerPlatform {
  final StreamController<BarcodeCapture?> _barcodes =
      StreamController<BarcodeCapture?>.broadcast();
  final StreamController<TorchState> _torch =
      StreamController<TorchState>.broadcast();
  final StreamController<double> _zoom = StreamController<double>.broadcast();

  int startCalls = 0;
  int stopCalls = 0;
  int pauseCalls = 0;
  int disposeCalls = 0;
  int toggleTorchCalls = 0;
  TorchState initialTorchState = TorchState.off;
  MobileScannerException? startError;
  Completer<void>? startGate;
  Completer<void>? pauseGate;

  void emit(BarcodeCapture capture) => _barcodes.add(capture);

  void emitError(Object error) => _barcodes.addError(error);

  void emitTorch(TorchState state) => _torch.add(state);

  @override
  Stream<BarcodeCapture?> get barcodesStream => _barcodes.stream;

  @override
  Stream<TorchState> get torchStateStream => _torch.stream;

  @override
  Stream<double> get zoomScaleStateStream => _zoom.stream;

  @override
  Widget buildCameraView() => const SizedBox.shrink();

  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async {
    startCalls++;
    await startGate?.future;
    final error = startError;
    if (error != null) {
      throw error;
    }
    return MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: initialTorchState,
      size: const Size(100, 100),
    );
  }

  @override
  Future<void> toggleTorch() async {
    toggleTorchCalls++;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    await pauseGate?.future;
  }

  @override
  Future<void> updateScanWindow(Rect? window) async {}

  // Deliberately keeps the streams open: a real camera plugin can still deliver
  // a frame that was already in flight when teardown began, and the test needs
  // to be able to model that.
  @override
  Future<void> dispose() async {
    disposeCalls++;
  }

  Future<void> close() async {
    await _barcodes.close();
    await _torch.close();
    await _zoom.close();
  }
}

void main() {
  testWidgets(
    'closing during failed camera start still pops without an uncaught error',
    (tester) async {
      final previous = MobileScannerPlatform.instance;
      final platform = _FakeScannerPlatform();
      final gate = Completer<void>();
      platform
        ..startGate = gate
        ..startError = const MobileScannerException(
          errorCode: MobileScannerErrorCode.permissionDenied,
        );
      MobileScannerPlatform.instance = platform;
      addTearDown(() async {
        MobileScannerPlatform.instance = previous;
        await platform.close();
      });
      late BuildContext host;
      await tester.pumpWidget(
        ProviderScope(
          child: TestApp(
            child: Builder(
              builder: (context) {
                host = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      var popped = false;
      unawaited(
        Navigator.of(host)
            .push<void>(MaterialPageRoute(builder: (_) => const ScanPage()))
            .then((_) {
              popped = true;
            }),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(platform.startCalls, 1);
      await tester.tap(find.byTooltip(currentAppLocalizations.close));
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();
      expect(popped, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
