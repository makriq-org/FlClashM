import 'dart:async';

import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/l10n/l10n.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/services/product_services.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AccessView extends ConsumerStatefulWidget {
  const AccessView({super.key});

  @override
  ConsumerState<AccessView> createState() => _AccessViewState();
}

class _AccessViewState extends ConsumerState<AccessView> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final _loadCompleter = Completer<List<Package>>();
  late AccessControlEditorState _editorState;
  bool _profileManaged = false;
  AndroidVpnOptions? _observedOptions;

  @override
  void initState() {
    super.initState();
    _syncResolvedAccessControl();
    globalState.activeProfileAccessControlNotifier
        .addListener(_handleProfileAccessControlChanged);
    _loadCompleter.complete(_loadPackages());
    _refreshObservedTunnelAccess();
  }

  @override
  void dispose() {
    globalState.activeProfileAccessControlNotifier
        .removeListener(_handleProfileAccessControlChanged);
    _persist();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleProfileAccessControlChanged() {
    if (!mounted) {
      return;
    }
    setState(_syncResolvedAccessControl);
    _refreshObservedTunnelAccess();
  }

  Future<void> _refreshObservedTunnelAccess() async {
    final options = await productServices.accessControl.readAppliedVpnOptions();
    if (!mounted) {
      return;
    }
    setState(() => _observedOptions = options);
  }

  void _syncResolvedAccessControl() {
    final profileAccessControl = globalState.activeProfileAccessControl;
    _editorState = productServices.accessControl.resolveEditorState(
      accessControl: ref.read(vpnSettingProvider).accessControl,
      profileAccessControl: profileAccessControl,
      previousState: _editorStateOrNull,
    );
    _profileManaged = profileAccessControl != null;
  }

  AccessControlEditorState? get _editorStateOrNull {
    try {
      return _editorState;
    } catch (_) {
      return null;
    }
  }

  void _persist() {
    if (_profileManaged || !_editorState.dirty) return;
    ref.read(vpnSettingProvider.notifier).updateState(
      (state) => productServices.accessControl.applyEditorState(
        state,
        _editorState,
      ),
    );
    _editorState = _editorState.copyWith(dirty: false);
  }

  void _toggleApp(String pkg) {
    setState(() {
      _editorState = productServices.accessControl.togglePackage(
        _editorState,
        pkg,
      );
    });
  }

  void _switchMode() {
    setState(() {
      _editorState = productServices.accessControl.switchMode(_editorState);
    });
  }

  Future<List<Package>> _loadPackages() =>
      productServices.accessControl.ensurePackagesLoaded(
        isMobileView: ref.read(isMobileViewProvider),
        cachedPackages: ref.read(packagesProvider),
        onPackagesLoaded: (packages) {
          ref.read(packagesProvider.notifier).value = packages;
        },
      );

  void _showModeHelp() {
    final appLocale = AppLocalizations.of(context);
    final title = _editorState.mode == AccessControlMode.acceptSelected
        ? appLocale.includeInVpn
        : appLocale.excludeFromVpn;
    final desc = _editorState.mode == AccessControlMode.acceptSelected
        ? appLocale.whitelistModeDesc
        : appLocale.blacklistModeDesc;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(desc),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      runTimeProvider.select((state) => state != null),
      (previous, next) {
        if (previous != next) {
          _refreshObservedTunnelAccess();
        }
      },
    );
    final packages = ref.watch(packagesProvider);
    final manualAccessControl =
        ref.watch(vpnSettingProvider.select((state) => state.accessControl));
    final filtered = productServices.accessControl.filterPackages(
      packages: packages,
      editorState: _editorState,
    );
    final appLocale = AppLocalizations.of(context);
    final isWhitelist = _editorState.isWhitelist;
    final tunnelAccessReport = productServices.tunnelAccess.inspect(
      manualAccessControl: manualAccessControl,
      profileAccessControl: globalState.activeProfileAccessControl,
      observedOptions: _observedOptions,
    );

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _persist();
      },
      child: Column(
        children: [
          _TunnelAccessDiagnostics(
            report: tunnelAccessReport,
            packages: packages,
          ),
          const Divider(height: 1),
          ListItem.switchItem(
            title: Row(
              children: [
                Text(appLocale.appAccessControl),
                if (_profileManaged) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.lock_outline, size: 16),
                ],
              ],
            ),
            subtitle: Text(appLocale.accessControlDesc),
            delegate: SwitchDelegate(
              value: _editorState.enabled,
              onChanged: _profileManaged
                  ? null
                  : (v) => setState(() {
                      _editorState = productServices.accessControl.setEnabled(
                        _editorState,
                        enabled: v,
                      );
                    }),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: DisabledMask(
              status: !_editorState.enabled,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    child: GestureDetector(
                      onLongPress: _showModeHelp,
                      child: SegmentedButton<AccessControlMode>(
                        segments: [
                          ButtonSegment(
                            value: AccessControlMode.acceptSelected,
                            label: Text(appLocale.includeInVpn),
                            icon: const Icon(Icons.check_circle_outline,
                                size: 18),
                          ),
                          ButtonSegment(
                            value: AccessControlMode.rejectSelected,
                            label: Text(appLocale.excludeFromVpn),
                            icon: const Icon(Icons.remove_circle_outline,
                                size: 18),
                          ),
                        ],
                        selected: {_editorState.mode},
                        onSelectionChanged:
                            _profileManaged ? null : (_) => _switchMode(),
                        showSelectedIcon: false,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: appLocale.search,
                        prefixIcon: const Icon(Icons.search, size: 20),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        suffixIcon: _editorState.query.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {
                                    _editorState = productServices.accessControl
                                        .setQuery(
                                      _editorState,
                                      '',
                                    );
                                  });
                                },
                              )
                            : null,
                      ),
                      onChanged: (v) => setState(() {
                        _editorState = productServices.accessControl.setQuery(
                          _editorState,
                          v,
                        );
                      }),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.android),
                          tooltip: appLocale.systemApp,
                          isSelected: _editorState.showSystemApps,
                          onPressed: () => setState(() {
                            _editorState = productServices.accessControl
                                .toggleShowSystemApps(_editorState);
                          }),
                        ),
                        IconButton(
                          icon: const Icon(Icons.wifi_off),
                          tooltip: appLocale.noNetworkApp,
                          isSelected: _editorState.showNoInternetApps,
                          onPressed: () => setState(() {
                            _editorState = productServices.accessControl
                                .toggleShowNoInternetApps(_editorState);
                          }),
                        ),
                        const Spacer(),
                        if (!_profileManaged &&
                            _editorState.selectedPackages.isNotEmpty)
                          TextButton.icon(
                            icon: const Icon(Icons.clear_all, size: 18),
                            label: Text('${_editorState.selectedPackages.length}'),
                            onPressed: () => setState(() {
                              _editorState = productServices.accessControl
                                  .clearSelection(_editorState);
                            }),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: FutureBuilder(
                      future: _loadCompleter.future,
                      builder: (_, snap) {
                        if (snap.connectionState != ConnectionState.done) {
                          return const Center(
                              child: CircularProgressIndicator());
                        }
                        if (filtered.isEmpty) {
                          return Center(
                            child: Text(
                              appLocale.noData,
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          );
                        }
                        return ListView.builder(
                          controller: _scrollController,
                          itemCount: filtered.length,
                          itemExtent: 72,
                          itemBuilder: (_, i) {
                            final pkg = filtered[i];
                            final selected = _editorState.selectedPackages
                                .contains(pkg.packageName);
                            return _AppTile(
                              package: pkg,
                              selected: selected,
                              isWhitelist: isWhitelist,
                              onTap: _profileManaged
                                  ? null
                                  : () => _toggleApp(pkg.packageName),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AppTile extends StatelessWidget {
  const _AppTile({
    required this.package,
    required this.selected,
    required this.isWhitelist,
    required this.onTap,
  });

  final Package package;
  final bool selected;
  final bool isWhitelist;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Color? color;
    final IconData icon;
    if (selected) {
      color = isWhitelist ? Colors.green : Colors.red;
      icon = isWhitelist ? Icons.check_circle : Icons.remove_circle;
    } else {
      color = null;
      icon = Icons.radio_button_unchecked;
    }

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: FutureBuilder<ImageProvider?>(
                future: productServices.accessControl.readPackageIcon(
                  package.packageName,
                ),
                builder: (_, snap) {
                  if (snap.data == null) return const SizedBox();
                  return Image(
                    image: snap.data!,
                    gaplessPlayback: true,
                    width: 48,
                    height: 48,
                  );
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    package.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    package.packageName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Icon(icon, color: color),
          ],
        ),
      ),
    );
  }
}

/// Read-only panel that shows what is actually included in / excluded from the
/// tunnel — driven by the profile config or the manual settings — so the page
/// can be trusted for diagnostics.
class _TunnelAccessDiagnostics extends StatelessWidget {
  const _TunnelAccessDiagnostics({
    required this.report,
    required this.packages,
  });

  final TunnelAccessReport report;
  final List<Package> packages;

  @override
  Widget build(BuildContext context) {
    final appLocale = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final selfBypass = report.selfBypassPackages.toSet();
    final realPackages = report.effectivePackages
        .where((pkg) => !selfBypass.contains(pkg))
        .toList(growable: false);
    final isWhitelist = report.isWhitelist;
    final allAppsThroughTunnel = !isWhitelist && realPackages.isEmpty;
    final count =
        isWhitelist ? report.effectivePackages.length : realPackages.length;

    final String summary;
    if (allAppsThroughTunnel) {
      summary = appLocale.tunnelAccessAllApps;
    } else if (isWhitelist) {
      summary = '${appLocale.tunnelAccessIncludeMode} · $count';
    } else {
      summary = '${appLocale.tunnelAccessExcludeMode} · $count';
    }

    final labels = <String, String>{
      for (final package in packages) package.packageName: package.label,
    };

    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        leading: Icon(
          isWhitelist ? Icons.vpn_lock : Icons.alt_route,
          color: theme.colorScheme.primary,
        ),
        title: Text(appLocale.effectiveTunnelAccess),
        subtitle: Row(
          children: [
            Expanded(
              child: Text(
                summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (report.hasObservedDrift) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.sync_problem,
                size: 16,
                color: theme.colorScheme.error,
              ),
            ],
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(
                    report.source == TunnelAccessSource.profile
                        ? Icons.description_outlined
                        : Icons.tune,
                    size: 16,
                  ),
                  label: Text(
                    report.source == TunnelAccessSource.profile
                        ? appLocale.tunnelAccessSourceProfile
                        : appLocale.tunnelAccessSourceManual,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    appLocale.effectiveTunnelAccessDesc,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (report.selfBypassPackages.isNotEmpty)
                  _TunnelAccessNote(
                    icon: Icons.shield_outlined,
                    text: appLocale.tunnelAccessSelfBypass,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                if (report.observation != null)
                  _TunnelAccessNote(
                    icon: report.hasObservedDrift
                        ? Icons.sync_problem
                        : Icons.verified_outlined,
                    text: report.hasObservedDrift
                        ? appLocale.tunnelAccessObservedMismatch
                        : appLocale.tunnelAccessObservedMatch,
                    color: report.hasObservedDrift
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
              ],
            ),
          ),
          if (report.effectivePackages.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: report.effectivePackages.length,
                itemBuilder: (_, index) {
                  final pkg = report.effectivePackages[index];
                  return _TunnelAccessAppTile(
                    packageName: pkg,
                    label: labels[pkg],
                    isSelf: selfBypass.contains(pkg),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _TunnelAccessNote extends StatelessWidget {
  const _TunnelAccessNote({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: color),
              ),
            ),
          ],
        ),
      );
}

class _TunnelAccessAppTile extends StatelessWidget {
  const _TunnelAccessAppTile({
    required this.packageName,
    required this.label,
    required this.isSelf,
  });

  final String packageName;
  final String? label;
  final bool isSelf;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: SizedBox(
        width: 32,
        height: 32,
        child: FutureBuilder<ImageProvider?>(
          future: productServices.accessControl.readPackageIcon(packageName),
          builder: (_, snap) {
            if (snap.data == null) {
              return const Icon(Icons.android, size: 28);
            }
            return Image(
              image: snap.data!,
              gaplessPlayback: true,
              width: 32,
              height: 32,
            );
          },
        ),
      ),
      title: Text(
        label ?? packageName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        packageName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: isSelf
          ? Icon(
              Icons.shield_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            )
          : null,
    );
  }
}
