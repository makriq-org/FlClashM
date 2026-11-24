import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('app isolation survives profile sync only while the profile names it', () {
    var next = syncProfileSettings(
      const PatchClashConfig(),
      {
        'tun': {'app-isolation': 'strict'},
      },
      ['tun.app-isolation'],
    );
    expect(next.tun.appIsolation, AppIsolationMode.strict);

    next = syncProfileSettings(
      const PatchClashConfig(),
      {
        'tun': {'app-isolation': ' Strict '},
      },
      ['tun.app-isolation'],
    );
    expect(next.tun.appIsolation, AppIsolationMode.strict);

    next = syncProfileSettings(next, {}, const []);
    expect(next.tun.appIsolation, AppIsolationMode.balanced);
  });

  test('an unknown profile value falls back to balanced instead of off', () {
    final next = syncProfileSettings(
      const PatchClashConfig(),
      {
        'tun': {'app-isolation': 'sometimes'},
      },
      ['tun.app-isolation'],
    );
    expect(next.tun.appIsolation, AppIsolationMode.balanced);
  });

  test('taking app isolation over keeps the local value on resync', () {
    final current = PatchClashConfig(
      tun: defaultTun.copyWith(appIsolation: AppIsolationMode.strict),
    );
    final synced = PatchClashConfig(
      tun: defaultTun.copyWith(appIsolation: AppIsolationMode.off),
    );
    final kept = keepOwnedSettings(current, synced, {
      'clash.tun.app-isolation',
    });
    expect(kept.tun.appIsolation, AppIsolationMode.strict);
    final released = keepOwnedSettings(current, synced, const {});
    expect(released.tun.appIsolation, AppIsolationMode.off);
  });

  test('applied isolation parsing keeps mode, source and failures apart', () {
    final applied = AppliedAppIsolation.parse(
      '{"appIsolation":{"mode":"strict","source":"profile",'
      '"status":"applied","detail":""}}',
    );
    expect(applied?.mode, AppIsolationMode.strict);
    expect(applied?.source, 'profile');
    expect(applied?.status, 'applied');
    expect(AppliedAppIsolation.parse('{"enable":true}'), isNull);
    expect(AppliedAppIsolation.parse(''), isNull);
    expect(AppliedAppIsolation.parse('not json'), isNull);
  });

  test('the locked row shows the profile mode, but takeover keeps it local', () {
    const local = AppIsolationMode.balanced;
    const applied = AppliedAppIsolation(
      mode: AppIsolationMode.strict,
      source: 'profile',
      status: 'applied',
      detail: '',
    );
    expect(
      effectiveAppIsolationMode(locked: true, applied: applied, local: local),
      AppIsolationMode.strict,
    );
    // Local settings win when the subscription does not own the mode.
    expect(
      effectiveAppIsolationMode(
        locked: true,
        applied: const AppliedAppIsolation(
          mode: AppIsolationMode.strict,
          source: 'user',
          status: 'applied',
          detail: '',
        ),
        local: local,
      ),
      local,
    );
    expect(
      effectiveAppIsolationMode(locked: false, applied: applied, local: local),
      local,
    );
    expect(
      effectiveAppIsolationMode(locked: true, applied: null, local: local),
      local,
    );
  });

  test('the setting is an owned clash key for the network page', () {
    expect(managedClashKeysOf(['tun.app-isolation']), {
      'clash.tun.app-isolation',
    });
    expect(networkPageKeys, contains('clash.tun.app-isolation'));
  });

  test('Tun serializes app isolation but never sends it to the engine', () {
    final tun = Tun.fromJson({'app-isolation': 'strict'});
    expect(tun.appIsolation, AppIsolationMode.strict);
    expect(tun.toJson()['app-isolation'], 'strict');
    expect(tun.coreJson.containsKey('app-isolation'), isFalse);

    expect(Tun.fromJson(const {}).appIsolation, AppIsolationMode.balanced);
    expect(
      Tun.fromJson({'app-isolation': 'nonsense'}).appIsolation,
      AppIsolationMode.balanced,
    );
  });
}
