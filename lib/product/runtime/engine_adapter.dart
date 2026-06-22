import 'package:flclashx/models/models.dart';

import '../compile/product_compile.dart';

abstract interface class EngineAdapter {
  Future<void> applyPendingUpdate();

  Future<void> prepareForRestart();

  Future<bool> isInitialized();

  Future<void> initialize({
    required InitParams initParams,
    required CoreState state,
  });

  Future<String> setupRuntimePlan(RuntimePlan runtimePlan);

  Future<String> updateRuntimeConfig(UpdateParams updateParams);

  Future<bool> start({String? notificationTitle});

  Future<void> stop();

  Future<DateTime?> readStartTime();

  Future<void> persistColdStart({
    required InitParams initParams,
    required RuntimePlan runtimePlan,
    required CoreState state,
  });
}
