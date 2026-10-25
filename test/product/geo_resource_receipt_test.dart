import 'dart:async';

import 'package:flclashx/core/controller.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/providers/action.dart';
import 'package:flclashx/providers/app.dart';
import 'package:flclashx/providers/core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Core extends Fake implements CoreController {
  final completion = Completer<String>();

  @override
  Future<String> updateGeoData(String type) => completion.future;
}

void main() {
  for (final fails in [false, true]) {
    test(
      'geo progress follows the terminal Go receipt, failure=$fails',
      () async {
        final core = _Core();
        final container = ProviderContainer(
          overrides: [
            coreHandlerProvider.overrideWithValue(core),
            coreStatusProvider.overrideWithValue(CoreStatus.connected),
          ],
        );
        addTearDown(container.dispose);
        const resource = GeoResource.GEOIP;
        final task = container
            .read(geoResourceActionProvider.notifier)
            .updateGeoResource(resource, announceSuccess: false);
        expect(
          container.read(isUpdatingProvider(resource.updatingKey)),
          isTrue,
        );
        if (fails) {
          core.completion.completeError(StateError('download failed'));
          await expectLater(task, throwsStateError);
        } else {
          core.completion.complete('');
          await task;
        }
        expect(
          container.read(isUpdatingProvider(resource.updatingKey)),
          isFalse,
        );
      },
    );
  }
}
