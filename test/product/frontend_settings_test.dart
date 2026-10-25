import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/backend/backend_client.dart';
import 'package:flclashx/product/backend/frontend_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'settings patches keep unknown fields and flush retains failed receipt',
    () async {
      final commands = <Map<String, dynamic>>[];
      var reject = false;
      final client = BackendClient(
        transport: (request) async {
          final method = request['method'];
          if (method == 'settings.patch') {
            commands.add(request['params'] as Map<String, dynamic>);
            return {
              'apiVersion': 1,
              'result': {
                'status': reject ? 'failed' : 'succeeded',
                if (reject) 'error': 'Settings rejected',
                if (reject) 'errorCode': 'invalid',
              },
            };
          }
          return {
            'apiVersion': 1,
            'result': method == 'snapshot'
                ? {
                    'seq': 1,
                    'runtime': {'instanceId': 'settings'},
                    'catalog': {
                      'revision': 1,
                      'profiles': [],
                      'settings': {
                        'futureKey': {'keep': true},
                      },
                    },
                  }
                : {},
          };
        },
        events: const Stream.empty(),
      );
      await client.attach();
      addTearDown(client.detach);
      final store = FrontendSettings(client: client);
      final initial = Config.fromJson(frontendSettings(client.sourceSettings));
      store.project(initial);
      await store.save(
        initial.copyWith(
          appSettingProps: initial.appSettingProps.copyWith(hidden: true),
        ),
      );
      final patch = commands.single['patch'] as Map;
      expect(patch, {
        'appSetting': {'hidden': true},
      });
      expect(client.sourceSettings['futureKey'], {'keep': true});
      reject = true;
      final rejected = initial.copyWith(
        appSettingProps: initial.appSettingProps.copyWith(hidden: false),
      );
      await expectLater(store.save(rejected), throwsA(isA<BackendException>()));
      await expectLater(store.flush(), throwsA(isA<BackendException>()));
      await expectLater(store.save(rejected), throwsA(isA<BackendException>()));
      reject = false;
      await store.save(
        initial.copyWith(
          appSettingProps: initial.appSettingProps.copyWith(hidden: true),
        ),
      );
      await store.flush();
    },
  );
}
