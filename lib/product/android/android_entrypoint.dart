import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/product/backend/backend.dart';
import 'package:flclashx/product/services/product_services.dart';
import 'package:flclashx/state.dart';

class AndroidEntrypoint {
  AndroidEntrypoint._();
  static final AndroidEntrypoint instance = AndroidEntrypoint._();

  Future<void> init() async {
    productServices.androidShell.bindTileCommands(
      onStart: handleStart,
      onStop: handleStop,
      onChangeMode: handleChangeMode,
    );
    await productServices.androidShell.signalServiceReady();
  }

  Future<void> handleStart() => globalState.appController.updateStatus(true);
  Future<void> handleStop() async {
    await backendClient.command('runtime.stop');
  }

  Future<void> handleChangeMode(String mode) async {
    final value = Mode.values.byName(mode);
    await backendClient.command('settings.patch', {
      'patch': {
        'patchClashConfig': {'mode': value.name},
      },
    });
    await productServices.androidShell.syncTileMode(value);
  }
}

final androidEntrypoint = AndroidEntrypoint.instance;
