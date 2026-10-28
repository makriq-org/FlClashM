import 'dart:async';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/plugins/app.dart';
import 'package:flclashx/product/services/product_services.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/ui/icons/icons.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
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

  final _completer = Completer();

  @override
  void initState() {
    super.initState();
    _controller = sheetScrollController(context);
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
    });
    ref.listenManual(
      accessControlViewProvider.select((state) => state.mode),
      (_, _) => _pinList(),
    );
    ref.listenManual(settingLockedProvider(accessControlSettingKey), (
      previous,
      next,
    ) {
      if (next && previous == false) {
        ref.read(accessControlStateProvider.notifier).value = ref
            .read(vpnSettingProvider)
            .accessControlProps
            .copyWith();
        _pinList();
      }
    });
    _completer.complete(_loadPackages());
  }

  @override
  void didSettleRoute() => setState(() {});

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
      _pinedList = ref.read(accessControlViewProvider).currentList;
    });
  }

  @override
  void dispose() {
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
          body: const AccessControlPanel(),
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
    final appLocalizations = context.appLocalizations;
    final res = await dialogs.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(text: appLocalizations.saveChanges),
    );
    if (res == null) {
      return;
    }
    if (res) {
      _handleSave();
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _handleSave() {
    final accessControl = ref.read(accessControlStateProvider);
    ref
        .read(vpnSettingProvider.notifier)
        .update(
          (state) => state.copyWith(
            accessControlProps: productServices.accessControl
                .normalizeManualAccess(accessControl),
          ),
        );
  }

  Future<void> _exportToClipboard() async {
    await globalState.safeRun(() {
      final currentList = ref.read(
        accessControlViewProvider.select((state) => state.currentList),
      );
      Clipboard.setData(ClipboardData(text: currentList.join('\n')));
    });
  }

  Future<void> _importFormClipboard() async {
    await globalState.safeRun(() async {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text;
      if (text == null) return;
      final list = text
          .split('\n')
          .where((name) => !selfPackageNames.contains(name));
      ref
          .read(accessControlStateProvider.notifier)
          .update((state) => state.copyWithNewList(list.toSet().toList()));
    });
  }

  void _returnToProvider() {
    ref
        .read(managedSettingsActionProvider.notifier)
        .release(accessControlSettingKey);
  }

  List<CommonPopupMenuItem> _buildMenuItems(
    BuildContext context, {
    required bool enable,
    required bool locked,
    required bool releasable,
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
      CommonPopupMenuItem(
        glyph: AppGlyphs.sliders,
        label: appLocalizations.settings,
        onPressed: _handleToSetting,
      ),
      if (releasable)
        CommonPopupMenuItem(
          glyph: AppGlyphs.lock,
          label: appLocalizations.returnToProvider,
          onPressed: _returnToProvider,
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
                return PackageListItem(
                  key: Key(package.packageName),
                  package: package,
                  value: selected.contains(package.packageName),
                  onChanged: (value) {
                    _handleSelected(package.packageName);
                  },
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
          ManagedSetting(
            settingKey: accessControlSettingKey,
            child: SurfaceScope(
              level: level,
              child: TonalButton(
                size: TonalButtonSize.compact,
                label: appLocalizations.turnOn,
                onPressed: () => _handleEnable(true),
              ),
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
    final appLocalizations = context.appLocalizations;
    final isLoading = ref.watch(loadingProvider(LoadingTag.access));
    final declared = ref.watch(profileDeclaredAccessProvider);
    final query = SearchQuery(ref.watch(queryProvider(QueryTag.access)));
    final packages = ref
        .watch(packagesProvider)
        .where((package) => !selfPackageNames.contains(package.packageName))
        .toList();
    final accessControl = ref.watch(accessControlViewProvider);
    final editor = ref.watch(accessControlStateProvider);
    final locked = ref.watch(settingLockedProvider(accessControlSettingKey));
    final owned = ref.watch(settingOwnedProvider(accessControlSettingKey));
    final releasable = ref.watch(
      settingReleasableProvider(accessControlSettingKey),
    );
    final resolvingProfile = !owned && declared.isLoading && !declared.hasValue;
    final profileFailed = !owned && declared.hasError;
    final profileUnavailable = resolvingProfile || profileFailed;
    final visibleNames = packages
        .whereVisible(
          isFilterSystemApp: accessControl.isFilterSystemApp,
          isFilterNonInternetApp: accessControl.isFilterNonInternetApp,
        )
        .map((package) => package.packageName)
        .toSet();
    final selectedNames = accessControl.currentList.toSet();
    final viewPackages = packages
        .getViewList(
          pinedList: _pinedList ?? accessControl.currentList,
          sortType: accessControl.sort,
          isFilterNonInternetApp: false,
          isFilterSystemApp: false,
        )
        .where(
          (package) =>
              visibleNames.contains(package.packageName) ||
              selectedNames.contains(package.packageName),
        )
        .whereMatches(query, (package) => [package.label, package.packageName])
        .toList();
    final viewPackageNameList = viewPackages.map((e) => e.packageName).toList();
    final valueList = selectedNames.intersection(viewPackageNameList.toSet());
    final needsInstalledAppsPermission =
        packages.isEmpty && !_installedAppsPermissionGranted;
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
    final manual = ref.watch(
      vpnSettingProvider.select((state) => state.accessControlProps),
    );
    final service = productServices.accessControl;
    final hasChanges =
        !profileUnavailable &&
        service.normalizeManualAccess(manual) !=
            service.normalizeManualAccess(editor);
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
        searchActions: profileUnavailable ? const [] : [?selectAllAction],
        title: context.appLocalizations.appAccessControl,
        confirmationAction: hasChanges
            ? IconButtonData(
                glyph: AppGlyphs.check,
                onPressed: _handleSave,
                tooltip: context.appLocalizations.save,
              )
            : null,
        menuItems: profileUnavailable
            ? const []
            : [
                ..._buildMenuItems(
                  context,
                  enable: accessControl.enable,
                  locked: locked,
                  releasable: releasable,
                ),
                if (selectAllAction != null)
                  CommonPopupMenuItem(
                    glyph: selectAllAction.glyph,
                    label: selectAllAction.tooltip!,
                    onPressed: selectAllAction.onPressed,
                  ),
              ],
        body: resolvingProfile
            ? const Center(child: CommonCircleLoading.page())
            : profileFailed
            ? NullStatus(
                label: appLocalizations.error,
                illustration: NullStatusIllustration.error,
                action: TonalButton(
                  size: TonalButtonSize.bar,
                  glyph: AppGlyphs.refresh,
                  label: appLocalizations.retry,
                  onPressed: () =>
                      ref.invalidate(profileDeclaredAccessProvider),
                ),
              )
            : AppBarClearance(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildBannerBar(
                      enable: accessControl.enable,
                      mode: accessControl.mode,
                      count: valueList.length,
                    ),
                    if (locked)
                      const ManagedSettingsHint(
                        keys: {accessControlSettingKey},
                      ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: needsInstalledAppsPermission
                          ? _buildInstalledAppsPermissionStatus()
                          : ManagedSetting(
                              settingKey: accessControlSettingKey,
                              child: DisabledMask(
                                status: !accessControl.enable,
                                child: _buildContent(
                                  packages: viewPackages,
                                  selected: selectedNames,
                                  isSearching: query.isNotEmpty,
                                ),
                              ),
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

class AccessControlPanel extends ConsumerWidget {
  const AccessControlPanel({super.key});

  static ConfigWriter<T> _writer<T>(
    AccessControlProps Function(AccessControlProps state, T value) update,
  ) {
    return (ref, value) => ref
        .read(accessControlStateProvider.notifier)
        .update((state) => update(state, value));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16)
          .copyWith(top: context.contentTopPadding, bottom: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          generateSection(
            items: [
              ManagedSetting(
                settingKey: accessControlSettingKey,
                child: ConfigOptionsItem<AccessControlMode>(
                  title: (l) => l.mode,
                  options: AccessControlMode.values,
                  textBuilder: (mode) => switch (mode) {
                    AccessControlMode.acceptSelected =>
                      appLocalizations.whitelistMode,
                    AccessControlMode.rejectSelected =>
                      appLocalizations.blacklistMode,
                  },
                  selector: accessControlViewProvider.select(
                    (state) => state.mode,
                  ),
                  onChanged: _writer(
                    (state, value) => state.copyWith(mode: value),
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
