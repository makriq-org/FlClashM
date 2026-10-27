import 'dart:async';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/core/core.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/plugins/app.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/product/services/product_services.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/ui/icons/icons.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AccessView extends ConsumerStatefulWidget {
  const AccessView({super.key});

  @override
  ConsumerState<AccessView> createState() => _AccessViewState();
}

class _AccessViewState extends ConsumerState<AccessView>
    with RouteSettledMixin<AccessView> {
  late ScrollController _controller;
  List<String>? _pinedList;
  bool _isInit = false;
  bool _installedAppsPermissionGranted = true;
  bool _resolvingProfile = false;
  ProfileManagedAccess _managed = ProfileManagedAccess.none;
  late final ProfileManagedAccessController _managedController;
  final _saveGuard = AccessControlSaveGuard();
  final _manualDraft = ManualAccessDraft();
  final _panelLocked = ValueNotifier(false);

  final _completer = Completer();

  @override
  void initState() {
    super.initState();
    _controller = sheetScrollController(context);
    _managedController = productServices.accessControl
        .createProfileManagedController(
          readProfileAccessControl: () async {
            final profile = ref.read(currentProfileProvider);
            return profile == null
                ? null
                : coreController.getProfileAccessControl(profile.id);
          },
        );
    final accessControl = ref
        .read(vpnSettingProvider.select((state) => state.accessControlProps))
        .copyWith();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ref.read(accessControlStateProvider.notifier).value = accessControl;
      _isInit = true;
      _pinList();
      unawaited(_refreshManaged());
    });
    ref.listenManual(
      currentProfileProvider,
      (_, _) => unawaited(_refreshManaged()),
    );
    ref.listenManual(runTimeProvider, (_, _) => unawaited(_refreshManaged()));
    ref.listenManual(
      accessControlStateProvider.select((state) => state.mode),
      (_, _) => _pinList(),
    );
    _completer.complete(_loadPackages());
  }

  @override
  void didSettleRoute() => setState(() {});

  Future<void> _refreshManaged() async {
    if (!mounted || !_isInit || !system.isAndroid) return;
    _saveGuard.invalidate();
    _panelLocked.value = true;
    setState(() => _resolvingProfile = true);
    final resolved = await _managedController.refresh(
      isRunning: ref.read(runTimeProvider) != null,
      activeProfileAccessControl: null,
    );
    if (!mounted || resolved == null) return;
    final wasManaged = _managed.managed;
    if (resolved.managed || wasManaged) {
      final old = ref.read(accessControlStateProvider);
      if (!wasManaged && resolved.managed) {
        _manualDraft.suspend(old);
      }
      final effective = resolved.managed
          ? resolved.effectiveAccessControl!.copyWith(
              sort: old.sort,
              isFilterSystemApp: old.isFilterSystemApp,
              isFilterNonInternetApp: old.isFilterNonInternetApp,
            )
          : _manualDraft.restore(
              ref.read(vpnSettingProvider).accessControlProps,
              viewSettings: old,
            );
      ref.read(accessControlStateProvider.notifier).value = effective;
    }
    setState(() {
      _managed = resolved;
      _resolvingProfile = false;
    });
    _panelLocked.value = resolved.managed;
    _pinList();
  }

  Future<void> _loadPackages() async {
    final action = ref.read(systemActionProvider.notifier);
    final packages = await action.getPackages();
    final granted =
        packages.isNotEmpty || await action.isInstalledAppsPermissionGranted();
    if (!mounted || granted == _installedAppsPermissionGranted) {
      return;
    }
    setState(() {
      _installedAppsPermissionGranted = granted;
    });
  }

  Future<void> _handleGrantInstalledAppsPermission() async {
    final appLocalizations = context.appLocalizations;
    final granted = await ref
        .read(systemActionProvider.notifier)
        .requestInstalledAppsPermission();
    if (!mounted) {
      return;
    }
    if (!granted) {
      final res = await dialogs.showMessage(
        message: TextSpan(
          text: appLocalizations.installedAppsPermissionDeniedMessage,
        ),
        confirmText: appLocalizations.settings,
      );
      if (res == true) {
        await app?.openAppSettings();
      }
      return;
    }
    await globalState.loadingRun(_loadPackages, tag: LoadingTag.access);
  }

  void _pinList() {
    if (!_isInit || !mounted) {
      return;
    }
    setState(() {
      _pinedList = ref.read(accessControlStateProvider).currentList;
    });
  }

  @override
  void dispose() {
    _managedController.dispose();
    _panelLocked.dispose();
    _controller.dispose();
    super.dispose();
  }

  IconButtonData _buildSelectAllAction({
    required bool isSelectedAll,
    required List<String> allValueList,
  }) {
    void onPressed() {
      ref.read(accessControlStateProvider.notifier).update((state) {
        final newSet = Set<String>.from(state.currentList);
        final isSelectedAll = newSet.containsAll(allValueList);
        if (isSelectedAll) {
          newSet.removeAll(allValueList);
        } else {
          newSet.addAll(allValueList);
        }
        return state.copyWithNewList(newSet.toList());
      });
    }

    final appLocalizations = context.appLocalizations;
    return isSelectedAll
        ? IconButtonData(
            glyph: AppGlyphs.deselect,
            tooltip: appLocalizations.cancelSelectAll,
            onPressed: onPressed,
          )
        : IconButtonData(
            glyph: AppGlyphs.selectAll,
            tooltip: appLocalizations.selectAll,
            onPressed: onPressed,
          );
  }

  Future<void> _handleToSetting() async {
    await showSheet<int>(
      context: context,
      builder: (context) {
        final appLocalizations = context.appLocalizations;
        return CommonScaffold(
          body: AccessControlPanel(locked: _panelLocked),
          title: appLocalizations.accessControlSettings,
        );
      },
    );
  }

  void _handleSelected(String packageName) {
    ref.read(accessControlStateProvider.notifier).update((state) {
      final newSet = Set<String>.from(state.currentList)
        ..addOrRemove(packageName);
      return state.copyWithNewList(newSet.toList());
    });
  }

  void _handleEnable(bool enable) {
    ref.read(accessControlStateProvider.notifier).update((state) {
      return state.copyWith(enable: enable);
    });
  }

  Future<void> _handleBack() async {
    if (_managed.managed) {
      final draft = _manualDraft.value;
      final res = await dialogs.showMessage(
        title: context.appLocalizations.tip,
        message: TextSpan(text: context.appLocalizations.discardChanges),
      );
      if (!mounted ||
          res != true ||
          !_managed.managed ||
          _manualDraft.value != draft) {
        return;
      }
      Navigator.of(context).pop();
      return;
    }
    final ticket = _saveGuard.capture(ref.read(accessControlStateProvider));
    final appLocalizations = context.appLocalizations;
    final res = await dialogs.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(text: appLocalizations.saveChanges),
    );
    if (!mounted || res == null) {
      return;
    }
    if (!_saveGuard.permits(
      ticket,
      currentDraft: ref.read(accessControlStateProvider),
      managed: _managed.managed,
      resolving: _resolvingProfile,
    )) {
      return;
    }
    if (res) {
      if (!_handleSave(ticket: ticket)) return;
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  AccessControlProps _getRealAccessControlProps(
    AccessControlProps accessControl,
  ) => productServices.accessControl.normalizeManualAccess(accessControl);

  bool _handleSave({(int, AccessControl)? ticket}) {
    if (!mounted) return false;
    final accessControl = ref.read(accessControlStateProvider);
    if (!_saveGuard.permits(
      ticket ?? _saveGuard.capture(accessControl),
      currentDraft: accessControl,
      managed: _managed.managed,
      resolving: _resolvingProfile,
    )) {
      return false;
    }
    ref
        .read(vpnSettingProvider.notifier)
        .update(
          (state) => state.copyWith(
            accessControlProps: _getRealAccessControlProps(accessControl),
          ),
        );
    return true;
  }

  Future<void> _exportToClipboard() async {
    await globalState.safeRun(() {
      final currentList = ref.read(
        accessControlStateProvider.select((state) => state.currentList),
      );
      Clipboard.setData(ClipboardData(text: currentList.join('\n')));
    });
  }

  Future<void> _importFormClipboard() async {
    final ticket = _saveGuard.capture(ref.read(accessControlStateProvider));
    await globalState.safeRun(() async {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text;
      if (!mounted ||
          text == null ||
          !_saveGuard.permits(
            ticket,
            currentDraft: ref.read(accessControlStateProvider),
            managed: _managed.managed,
            resolving: _resolvingProfile,
          ))
        return;
      final list = text.split('\n');
      ref
          .read(accessControlStateProvider.notifier)
          .update((state) => state.copyWithNewList(list.toSet().toList()));
    });
  }

  List<CommonPopupMenuItem> _buildMenuItems(
    BuildContext context, {
    required bool enable,
    required bool locked,
  }) {
    final appLocalizations = context.appLocalizations;
    return [
      if (!locked)
        CommonPopupMenuItem(
          glyph: AppGlyphs.toggle,
          label: appLocalizations.accessControl,
          subItems: [
            CommonPopupMenuItem(
              label: appLocalizations.turnOn,
              checked: enable,
              onPressed: () => _handleEnable(true),
            ),
            CommonPopupMenuItem(
              label: appLocalizations.turnOff,
              checked: !enable,
              onPressed: () => _handleEnable(false),
            ),
          ],
        ),
      if (!locked)
        CommonPopupMenuItem(
          glyph: AppGlyphs.sliders,
          label: appLocalizations.settings,
          onPressed: _handleToSetting,
        ),
      CommonPopupMenuItem(
        glyph: AppGlyphs.moreCircle,
        label: appLocalizations.action,
        subItems: [
          CommonPopupMenuItem(
            glyph: AppGlyphs.copy,
            label: appLocalizations.clipboardExport,
            onPressed: _exportToClipboard,
          ),
          if (!locked)
            CommonPopupMenuItem(
              glyph: AppGlyphs.paste,
              label: appLocalizations.clipboardImport,
              onPressed: _importFormClipboard,
            ),
        ],
      ),
    ];
  }

  Widget _buildContent({
    required List<Package> packages,
    required Set<String> selected,
    required bool isSearching,
    required bool locked,
  }) {
    return FutureBuilder(
      future: _completer.future,
      builder: (context, snapshot) {
        final appLocalizations = context.appLocalizations;
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CommonCircleLoading.page());
        }
        return NullStatusSwitcher(
          isEmpty: packages.isEmpty,
          isSearching: isSearching,
          nullStatus: NullStatus(
            label: appLocalizations.noData,
            illustration: NullStatusIllustration.apps,
          ),
          child: CommonScrollBar(
            controller: _controller,
            child: ListView.builder(
              controller: _controller,
              padding: EdgeInsets.only(bottom: BottomInsetScope.of(context)),
              scrollCacheExtent: arrivalScrollCacheExtent(routeSettled),
              itemCount: packages.length,
              itemExtent: 72,
              itemBuilder: (_, index) {
                final package = packages[index];
                return Opacity(
                  opacity: locked ? 0.5 : 1,
                  child: IgnorePointer(
                    ignoring: locked,
                    child: PackageListItem(
                      key: Key(package.packageName),
                      package: package,
                      value: selected.contains(package.packageName),
                      onChanged: (value) {
                        _handleSelected(package.packageName);
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildInstalledAppsPermissionStatus() {
    final appLocalizations = context.appLocalizations;
    return NullStatus(
      label: appLocalizations.installedAppsPermissionRequired,
      description: appLocalizations.installedAppsPermissionDesc,
      illustration: NullStatusIllustration.permission,
      action: TonalButton(
        size: TonalButtonSize.bar,
        glyph: AppGlyphs.lockOpen,
        label: appLocalizations.authorize,
        onPressed: _handleGrantInstalledAppsPermission,
      ),
    );
  }

  Widget _buildBannerBar({
    required bool enable,
    required AccessControlMode mode,
    required int count,
    required bool locked,
  }) {
    final appLocalizations = context.appLocalizations;
    final level = context.raisedSurfaceLevel;
    final backgroundColor = level.colorOf(context.colorScheme);
    if (!enable) {
      return MaterialBanner(
        backgroundColor: backgroundColor,
        dividerColor: Colors.transparent,
        leading: GlyphIcon(AppGlyphs.info, color: context.colorScheme.outline),
        content: Text(
          appLocalizations.accessControlDisabledDesc,
          style: TextStyle(color: context.colorScheme.onSurfaceVariant),
        ),
        actions: [
          SurfaceScope(
            level: level,
            child: TonalButton(
              size: TonalButtonSize.compact,
              label: appLocalizations.turnOn,
              onPressed: locked ? null : () => _handleEnable(true),
            ),
          ),
        ],
      );
    }
    final describe = mode == AccessControlMode.acceptSelected
        ? appLocalizations.accessControlAllowDesc
        : appLocalizations.accessControlNotAllowDesc;
    final textStyle = AppTextStyle.subheadline
        .of(context, emphasized: true)
        .copyWith(color: context.colorScheme.onPrimary);
    return MaterialBanner(
      backgroundColor: backgroundColor,
      dividerColor: Colors.transparent,
      content: Text(describe),
      actions: [
        Card.filled(
          color: context.colorScheme.primary,
          elevation: 0,
          shape: AppShape.md,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(appLocalizations.selected, style: textStyle),
                const SizedBox(width: 4),
                Flexible(child: Text('$count', style: textStyle)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _onSearch(String value) {
    ref.read(queryProvider(QueryTag.access).notifier).value = value;
    _pinList();
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(loadingProvider(LoadingTag.access));
    final query = SearchQuery(ref.watch(queryProvider(QueryTag.access)));
    final packages = ref.watch(packagesProvider);
    final accessControl = ref.watch(accessControlStateProvider);
    final visibleNames = packages
        .whereVisible(
          isFilterSystemApp: accessControl.isFilterSystemApp,
          isFilterNonInternetApp: accessControl.isFilterNonInternetApp,
        )
        .map((package) => package.packageName)
        .toSet();
    final managedNames = accessControl.currentList.toSet();
    final viewPackages = packages
        .getViewList(
          pinedList: _pinedList ?? [],
          sortType: accessControl.sort,
          isFilterNonInternetApp: false,
          isFilterSystemApp: false,
        )
        .where(
          (package) =>
              visibleNames.contains(package.packageName) ||
              (_managed.managed && managedNames.contains(package.packageName)),
        )
        .whereMatches(query, (package) => [package.label, package.packageName])
        .toList();
    final mode = accessControl.mode;
    final currentList = accessControl.currentList;
    final viewPackageNameList = viewPackages.map((e) => e.packageName).toList();
    final valueList = currentList.intersection(viewPackageNameList);
    final needsInstalledAppsPermission =
        packages.isEmpty && !_installedAppsPermissionGranted;
    final locked = _managed.managed || _resolvingProfile;
    final selectAllAction =
        !locked &&
            accessControl.enable &&
            !needsInstalledAppsPermission &&
            viewPackageNameList.isNotEmpty
        ? _buildSelectAllAction(
            isSelectedAll: valueList.length == viewPackageNameList.length,
            allValueList: viewPackageNameList,
          )
        : null;
    final manualDraft = _manualDraft.value ?? accessControl;
    final draftChanged = ref.watch(
      vpnSettingProvider.select(
        (state) =>
            _getRealAccessControlProps(state.accessControlProps) !=
            _getRealAccessControlProps(manualDraft),
      ),
    );
    final hasChanges = _saveGuard.shouldConfirmExit(draftChanged: draftChanged);
    return CommonPopScope(
      onPop: hasChanges
          ? (_) {
              _handleBack();
              return false;
            }
          : null,
      child: CommonScaffold(
        isLoading: isLoading,
        searchState: AppBarSearchState(onSearch: _onSearch),
        searchActions: [?selectAllAction],
        title: context.appLocalizations.appAccessControl,
        confirmationAction: hasChanges && !locked
            ? IconButtonData(
                glyph: AppGlyphs.check,
                onPressed: () => _handleSave(),
                tooltip: context.appLocalizations.save,
              )
            : null,
        menuItems: [
          ..._buildMenuItems(
            context,
            enable: accessControl.enable,
            locked: locked,
          ),
          if (selectAllAction != null)
            CommonPopupMenuItem(
              glyph: selectAllAction.glyph,
              label: selectAllAction.tooltip!,
              onPressed: selectAllAction.onPressed,
            ),
        ],
        body: AppBarClearance(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildBannerBar(
                enable: accessControl.enable,
                mode: mode,
                count: valueList.length,
                locked: locked,
              ),
              if (_managed.managed ||
                  _managed.notice != ProfileManagedAccessNotice.none)
                const SizedBox(height: 12),
              if (_managed.managed)
                ManagedSettingsMessage(
                  message: context.appLocalizations.accessControlProfileManaged,
                ),
              if (_managed.notice != ProfileManagedAccessNotice.none)
                ProductAccessControlNotice(
                  message: _managed.notice == ProfileManagedAccessNotice.drift
                      ? context.appLocalizations.accessControlDriftNote
                      : context
                            .appLocalizations
                            .accessControlVerificationUnavailableNote,
                ),
              const SizedBox(height: 8),
              Expanded(
                child: needsInstalledAppsPermission
                    ? _buildInstalledAppsPermissionStatus()
                    : _buildContent(
                        packages: viewPackages,
                        selected: valueList.toSet(),
                        isSearching: query.isNotEmpty,
                        locked: locked || !accessControl.enable,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PackageListItem extends StatelessWidget {
  final Package package;
  final bool value;
  final void Function(bool?) onChanged;

  const PackageListItem({
    super.key,
    required this.package,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListItem.checkbox(
      leading: PackageIcon(packageName: package.packageName, size: 48),
      title: Text(
        package.label,
        style: const TextStyle(overflow: TextOverflow.ellipsis),
        maxLines: 1,
      ),
      subtitle: Text(
        package.packageName,
        style: const TextStyle(overflow: TextOverflow.ellipsis),
        maxLines: 1,
      ),
      value: value,
      onChanged: onChanged,
    );
  }
}

class AccessControlPanel extends StatelessWidget {
  const AccessControlPanel({super.key, required this.locked});
  final ValueListenable<bool> locked;

  static ConfigWriter<T> _writer<T>(
    AccessControlProps Function(AccessControlProps state, T value) update,
  ) {
    return (ref, value) => ref
        .read(accessControlStateProvider.notifier)
        .update((state) => update(state, value));
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: locked,
    builder: (context, managed, _) => _buildPanel(context, managed),
  );

  Widget _buildPanel(BuildContext context, bool managed) {
    final appLocalizations = context.appLocalizations;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16)
          .copyWith(top: context.contentTopPadding, bottom: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          generateSection(
            items: [
              Opacity(
                opacity: managed ? 0.5 : 1,
                child: IgnorePointer(
                  key: const ValueKey('access-control-mode-lock'),
                  ignoring: managed,
                  child: ConfigOptionsItem<AccessControlMode>(
                    title: (l) => l.mode,
                    options: AccessControlMode.values,
                    textBuilder: (mode) => switch (mode) {
                      AccessControlMode.acceptSelected =>
                        appLocalizations.whitelistMode,
                      AccessControlMode.rejectSelected =>
                        appLocalizations.blacklistMode,
                    },
                    selector: accessControlStateProvider.select(
                      (state) => state.mode,
                    ),
                    onChanged: _writer(
                      (state, value) => state.copyWith(mode: value),
                    ),
                  ),
                ),
              ),
              ConfigOptionsItem<AccessSortType>(
                title: (l) => l.sort,
                options: AccessSortType.values,
                textBuilder: (type) => switch (type) {
                  AccessSortType.none => appLocalizations.defaultText,
                  AccessSortType.name => appLocalizations.name,
                  AccessSortType.time => appLocalizations.time,
                },
                selector: accessControlStateProvider.select(
                  (state) => state.sort,
                ),
                onChanged: _writer(
                  (state, value) => state.copyWith(sort: value),
                ),
              ),
            ],
          ),
          generateSection(
            title: appLocalizations.source,
            items: [
              ConfigToggleItem(
                title: (l) => l.systemApp,
                selector: accessControlStateProvider.select(
                  (state) => !state.isFilterSystemApp,
                ),
                onChanged: _writer(
                  (state, value) => state.copyWith(isFilterSystemApp: !value),
                ),
              ),
              ConfigToggleItem(
                title: (l) => l.noNetworkApp,
                selector: accessControlStateProvider.select(
                  (state) => !state.isFilterNonInternetApp,
                ),
                onChanged: _writer(
                  (state, value) =>
                      state.copyWith(isFilterNonInternetApp: !value),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
