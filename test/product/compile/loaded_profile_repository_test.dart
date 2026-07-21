import 'dart:async';

import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/product_compile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const profile = Profile(
    id: 'profile-cache',
    autoUpdateDuration: Duration.zero,
  );

  test('shares YAML/script work for one complete profile revision', () async {
    final repository = LoadedProfileRepository();
    const revision = RawProfileRevision(
      profile: profile,
      lastModifiedMicros: 10,
      fileSize: 100,
      scriptId: 'script-1',
      scriptContent: 'function main(config) { return config; }',
    );
    final loadCompleter = Completer<RawProfile>();
    var loadCalls = 0;

    Future<RawProfile> loader() {
      loadCalls++;
      return loadCompleter.future;
    }

    final first = repository.load(revision, loader);
    final concurrent = repository.load(revision, loader);
    loadCompleter.complete(
      RawProfile.fromConfig(
        profile: profile,
        config: const {'proxies': []},
        revision: revision,
      ),
    );
    final loaded = await first;

    expect(await concurrent, same(loaded));
    expect(await repository.load(revision, loader), same(loaded));
    expect(loadCalls, 1);
  });

  test('invalidates only on compiler-relevant profile revisions', () async {
    final repository = LoadedProfileRepository();
    var loadCalls = 0;

    Future<RawProfile> load(RawProfileRevision revision) =>
        repository.load(revision, () async {
          loadCalls++;
          return RawProfile.fromConfig(
            profile: revision.profile,
            config: const {'proxies': []},
            revision: revision,
          );
        });

    await load(const RawProfileRevision(
      profile: profile,
      lastModifiedMicros: 10,
      fileSize: 100,
      scriptId: 'script-1',
      scriptContent: 'v1',
    ));
    await load(const RawProfileRevision(
      profile: profile,
      lastModifiedMicros: 11,
      fileSize: 100,
      scriptId: 'script-1',
      scriptContent: 'v1',
    ));
    await load(const RawProfileRevision(
      profile: profile,
      lastModifiedMicros: 11,
      fileSize: 100,
      scriptId: 'script-1',
      scriptContent: 'v2',
    ));
    await load(RawProfileRevision(
      profile: profile.copyWith(selectedMap: const {'Proxy': 'Node'}),
      lastModifiedMicros: 11,
      fileSize: 100,
      scriptId: 'script-1',
      scriptContent: 'v2',
    ));
    await load(RawProfileRevision(
      profile: profile.copyWith(
        overrideData: const OverrideData(enable: true),
      ),
      lastModifiedMicros: 11,
      fileSize: 100,
      scriptId: 'script-1',
      scriptContent: 'v2',
    ));

    expect(loadCalls, 4);
  });
}
