// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../action.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(CommonAction)
final commonActionProvider = CommonActionProvider._();

final class CommonActionProvider extends $NotifierProvider<CommonAction, void> {
  CommonActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'commonActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$commonActionHash();

  @$internal
  @override
  CommonAction create() => CommonAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$commonActionHash() => r'3fc042e88ea83d55dae7322669e51929a6b8b77e';

abstract class _$CommonAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(ManagedSettingsAction)
final managedSettingsActionProvider = ManagedSettingsActionProvider._();

final class ManagedSettingsActionProvider
    extends $NotifierProvider<ManagedSettingsAction, void> {
  ManagedSettingsActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'managedSettingsActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$managedSettingsActionHash();

  @$internal
  @override
  ManagedSettingsAction create() => ManagedSettingsAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$managedSettingsActionHash() =>
    r'59705310194c3c0463500663b105280bf45f1d16';

abstract class _$ManagedSettingsAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(ProfileHeadersAction)
final profileHeadersActionProvider = ProfileHeadersActionProvider._();

final class ProfileHeadersActionProvider
    extends $NotifierProvider<ProfileHeadersAction, void> {
  ProfileHeadersActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'profileHeadersActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$profileHeadersActionHash();

  @$internal
  @override
  ProfileHeadersAction create() => ProfileHeadersAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$profileHeadersActionHash() =>
    r'b0467bb23c8f75875e5ab9a43053be5591931452';

abstract class _$ProfileHeadersAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// The current subscription's or file's config keys become the app's
/// settings on every update and switch (see [syncProfileSettings]); a custom
/// profile has no file and a scripted one may rewrite the keys, so both skip.

@ProviderFor(ProfileSettingsAction)
final profileSettingsActionProvider = ProfileSettingsActionProvider._();

/// The current subscription's or file's config keys become the app's
/// settings on every update and switch (see [syncProfileSettings]); a custom
/// profile has no file and a scripted one may rewrite the keys, so both skip.
final class ProfileSettingsActionProvider
    extends $NotifierProvider<ProfileSettingsAction, void> {
  /// The current subscription's or file's config keys become the app's
  /// settings on every update and switch (see [syncProfileSettings]); a custom
  /// profile has no file and a scripted one may rewrite the keys, so both skip.
  ProfileSettingsActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'profileSettingsActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$profileSettingsActionHash();

  @$internal
  @override
  ProfileSettingsAction create() => ProfileSettingsAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$profileSettingsActionHash() =>
    r'eceedfc501eae04a04b94e400224b9b436941f0d';

/// The current subscription's or file's config keys become the app's
/// settings on every update and switch (see [syncProfileSettings]); a custom
/// profile has no file and a scripted one may rewrite the keys, so both skip.

abstract class _$ProfileSettingsAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(SetupAction)
final setupActionProvider = SetupActionProvider._();

final class SetupActionProvider extends $NotifierProvider<SetupAction, void> {
  SetupActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'setupActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$setupActionHash();

  @$internal
  @override
  SetupAction create() => SetupAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$setupActionHash() => r'a9e5f32065cccc20f81d153128eca82fe6b82710';

abstract class _$SetupAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(BackupAction)
final backupActionProvider = BackupActionProvider._();

final class BackupActionProvider extends $NotifierProvider<BackupAction, void> {
  BackupActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'backupActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$backupActionHash();

  @$internal
  @override
  BackupAction create() => BackupAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$backupActionHash() => r'5cffb0396005415a2459604c1d953da0c6abdf9c';

abstract class _$BackupAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(CoreAction)
final coreActionProvider = CoreActionProvider._();

final class CoreActionProvider extends $NotifierProvider<CoreAction, void> {
  CoreActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'coreActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$coreActionHash();

  @$internal
  @override
  CoreAction create() => CoreAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$coreActionHash() => r'aea0de93b7cc060cee6e6e040235f9dad009be48';

abstract class _$CoreAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(SystemAction)
final systemActionProvider = SystemActionProvider._();

final class SystemActionProvider extends $NotifierProvider<SystemAction, void> {
  SystemActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'systemActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$systemActionHash();

  @$internal
  @override
  SystemAction create() => SystemAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$systemActionHash() => r'5601a62857e9529a0b3005d2426f674f8d708819';

abstract class _$SystemAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(StoreAction)
final storeActionProvider = StoreActionProvider._();

final class StoreActionProvider extends $NotifierProvider<StoreAction, void> {
  StoreActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'storeActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$storeActionHash();

  @$internal
  @override
  StoreAction create() => StoreAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$storeActionHash() => r'584191d819cce0fda485e991045e3206956f80a0';

abstract class _$StoreAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(ThemeAction)
final themeActionProvider = ThemeActionProvider._();

final class ThemeActionProvider extends $NotifierProvider<ThemeAction, void> {
  ThemeActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'themeActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$themeActionHash();

  @$internal
  @override
  ThemeAction create() => ThemeAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$themeActionHash() => r'f33484cafdb1c8dec472f86f03ed4136c12770a0';

abstract class _$ThemeAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(ProxiesAction)
final proxiesActionProvider = ProxiesActionProvider._();

final class ProxiesActionProvider
    extends $NotifierProvider<ProxiesAction, void> {
  ProxiesActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'proxiesActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$proxiesActionHash();

  @$internal
  @override
  ProxiesAction create() => ProxiesAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$proxiesActionHash() => r'93e22e0b4edf20b578de437b1a82468a68aba141';

abstract class _$ProxiesAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(ProfilesAction)
final profilesActionProvider = ProfilesActionProvider._();

final class ProfilesActionProvider
    extends $NotifierProvider<ProfilesAction, void> {
  ProfilesActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'profilesActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$profilesActionHash();

  @$internal
  @override
  ProfilesAction create() => ProfilesAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$profilesActionHash() => r'7e39c069de5bd51401ff46f05e83ee56d5308fef';

abstract class _$ProfilesAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(ScriptsAction)
final scriptsActionProvider = ScriptsActionProvider._();

final class ScriptsActionProvider
    extends $NotifierProvider<ScriptsAction, void> {
  ScriptsActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'scriptsActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$scriptsActionHash();

  @$internal
  @override
  ScriptsAction create() => ScriptsAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$scriptsActionHash() => r'f4ec8e120ae8163e4b7bb78636c30d75264de87d';

abstract class _$ScriptsAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(ClashProvidersAction)
final clashProvidersActionProvider = ClashProvidersActionProvider._();

final class ClashProvidersActionProvider
    extends $NotifierProvider<ClashProvidersAction, void> {
  ClashProvidersActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'clashProvidersActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$clashProvidersActionHash();

  @$internal
  @override
  ClashProvidersAction create() => ClashProvidersAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$clashProvidersActionHash() =>
    r'6cfab9c85c84bec3c59c24f9ff0078ef9de3fd28';

abstract class _$ClashProvidersAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(IconSetsAction)
final iconSetsActionProvider = IconSetsActionProvider._();

final class IconSetsActionProvider
    extends $NotifierProvider<IconSetsAction, void> {
  IconSetsActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'iconSetsActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$iconSetsActionHash();

  @$internal
  @override
  IconSetsAction create() => IconSetsAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$iconSetsActionHash() => r'2568fa51c9ac71e3f0b5c990db458ddc7337ee88';

abstract class _$IconSetsAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(GeoResourceAction)
final geoResourceActionProvider = GeoResourceActionProvider._();

final class GeoResourceActionProvider
    extends $NotifierProvider<GeoResourceAction, void> {
  GeoResourceActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'geoResourceActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$geoResourceActionHash();

  @$internal
  @override
  GeoResourceAction create() => GeoResourceAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$geoResourceActionHash() => r'0c51366685262ad99f7965bc998aee87690ee1b6';

abstract class _$GeoResourceAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(ResourcesAction)
final resourcesActionProvider = ResourcesActionProvider._();

final class ResourcesActionProvider
    extends $NotifierProvider<ResourcesAction, void> {
  ResourcesActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'resourcesActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$resourcesActionHash();

  @$internal
  @override
  ResourcesAction create() => ResourcesAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$resourcesActionHash() => r'4789f340b60eadbbc3bc124f296bbeaa35121ba6';

abstract class _$ResourcesAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(UpdatingAction)
final updatingActionProvider = UpdatingActionProvider._();

final class UpdatingActionProvider
    extends $NotifierProvider<UpdatingAction, void> {
  UpdatingActionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'updatingActionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$updatingActionHash();

  @$internal
  @override
  UpdatingAction create() => UpdatingAction();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$updatingActionHash() => r'f98e26e80cc700f84e880393d0b280a08c37789b';

abstract class _$UpdatingAction extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
