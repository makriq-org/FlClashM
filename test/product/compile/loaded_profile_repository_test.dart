import 'dart:async';

import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/product_compile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const profile = Profile(
    id: 'profile-cache',
    autoUpdateDuration: Duration.zero,
  );
  const revision = RawProfileRevision(
    profileId: 'profile-cache',
    overrideData: OverrideData(),
    lastModifiedMicros: 10,
    changedMicros: 11,
    fileSize: 100,
    scriptId: 'script-1',
    scriptContent: 'v1',
  );

  test('shares one in-flight load and caches the exact revision', () async {
    final repository = LoadedProfileRepository();
    final completer = Completer<RawProfile>();
    var calls = 0;

    Future<RawProfile> loader() {
      calls++;
      return completer.future;
    }

    final first = repository.load(revision, loader);
    final concurrent = repository.load(revision, loader);
    completer.complete(
      RawProfile.fromConfig(
        profile: profile,
        config: const {'proxies': []},
        revision: revision,
      ),
    );
    final loaded = await first;

    expect(await concurrent, same(loaded));
    expect(await repository.load(revision, loader), same(loaded));
    expect(calls, 1);
  });

  test('clear prevents a stale in-flight load from repopulating cache',
      () async {
    final repository = LoadedProfileRepository();
    final staleCompleter = Completer<RawProfile>();

    final stale = repository.load(revision, () => staleCompleter.future);
    repository.clear();
    final fresh = repository.load(
      revision,
      () async => RawProfile.fromConfig(
        profile: profile,
        config: const {'revision': 'fresh'},
        revision: revision,
      ),
    );
    staleCompleter.complete(
      RawProfile.fromConfig(
        profile: profile,
        config: const {'revision': 'stale'},
        revision: revision,
      ),
    );

    expect((await stale).config['revision'], 'stale');
    expect((await fresh).config['revision'], 'fresh');
    expect(
      (await repository.load(
        revision,
        () => throw StateError('unexpected reload'),
      ))
          .config['revision'],
      'fresh',
    );
  });

  test('reloads when the profile revision changes', () async {
    final repository = LoadedProfileRepository();
    var calls = 0;

    Future<RawProfile> load(RawProfileRevision currentRevision) async {
      calls++;
      return RawProfile.fromConfig(
        profile: profile,
        config: {'load': calls},
        revision: currentRevision,
      );
    }

    await repository.load(revision, () => load(revision));
    final changedRevision = RawProfileRevision(
      profileId: revision.profileId,
      overrideData: revision.overrideData,
      lastModifiedMicros: revision.lastModifiedMicros,
      changedMicros: revision.changedMicros + 1,
      fileSize: revision.fileSize,
      scriptId: revision.scriptId,
      scriptContent: revision.scriptContent,
    );
    final reloaded = await repository.load(
      changedRevision,
      () => load(changedRevision),
    );

    expect(reloaded.config['load'], 2);
    expect(calls, 2);
  });

  test('freezes cached profile config deeply', () {
    final profileConfig = <String, dynamic>{
      'tun': <String, dynamic>{'enable': true},
      'rules': <dynamic>['MATCH,DIRECT'],
    };
    final rawProfile = RawProfile.fromConfig(
      profile: profile,
      config: profileConfig,
      revision: revision,
    );

    expect(
      () => rawProfile.config['tun']['enable'] = false,
      throwsUnsupportedError,
    );
    expect(
      () => (rawProfile.config['rules'] as List).add('DOMAIN,test,DIRECT'),
      throwsUnsupportedError,
    );
  });
}
