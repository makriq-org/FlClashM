part of '../action.dart';

@Riverpod(keepAlive: true)
class StoreAction extends _$StoreAction {
  @override
  void build() {}
  Future<void> shakingStore() async {
    await backendClient.command('storage.collect');
  }

  void savePreferencesDebounce() {
    unawaited(
      globalState.safeRun(
        () => frontendSettingsStore.save(ref.read(configProvider)),
      ),
    );
  }

  Future<void> handleClear({bool everything = false}) async {
    await backendClient.command(
      everything ? 'data.reset' : 'storage.clearCache',
    );
  }
}
