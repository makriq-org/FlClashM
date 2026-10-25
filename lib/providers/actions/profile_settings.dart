part of '../action.dart';

typedef ProfileSettingsSource = ({
  String? id,
  DateTime? updatedAt,
  ProfileType? type,
  ExtendType? extendType,
});

ProfileSettingsSource profileSettingsSourceOf(Profile? profile) => (
  id: profile?.id,
  updatedAt: profile?.lastUpdateDate,
  type: profile?.type,
  extendType: profile?.extendType,
);

/// The current subscription's or file's config keys become the app's
/// settings on every update and switch (see [syncProfileSettings]); a custom
/// profile has no file and a scripted one may rewrite the keys, so both skip.
@Riverpod(keepAlive: true)
class ProfileSettingsAction extends _$ProfileSettingsAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  int _generation = 0;

  @override
  void build() {
    ref.listen(
      currentProfileProvider.select(profileSettingsSourceOf),
      (_, next) => scheduleMicrotask(() => unawaited(apply(next))),
    );
    scheduleMicrotask(
      () => unawaited(
        apply(profileSettingsSourceOf(ref.read(currentProfileProvider))),
      ),
    );
  }

  Future<void> apply(ProfileSettingsSource source) async {
    final generation = ++_generation;
    final id = source.id;
    if (id == null ||
        source.type == ProfileType.custom ||
        source.extendType == ExtendType.script) {
      ref.read(managedClashKeysProvider.notifier).set(const {});
      return;
    }
    final ProfileBase base;
    try {
      base = (await _core.getProfileBase(id)).base;
    } catch (error) {
      commonPrint.log(
        'profile $id settings not read: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
      return;
    }
    if (generation != _generation) {
      return;
    }
    ref.read(managedClashKeysProvider.notifier).set(managedClashKeysOf(base.present));
  }
}
