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
  bool _hasDrift = false;

  @override
  void initState() {
    super.initState();
    _editorState = productServices.accessControl.resolveEditorState(
      accessControl: ref.read(vpnSettingProvider).accessControl,
      profileAccessControl: globalState.activeProfileAccessControl,
      previousState: null,
    );
    _profileManaged = globalState.activeProfileAccessControl != null;
    globalState.activeProfileAccessControlNotifier
        .addListener(_handleProfileAccessControlChanged);
    _loadCompleter.complete(_loadPackages());
    unawaited(_refreshManagedAccess());
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
    unawaited(_refreshManagedAccess());
  }

  /// Hybrid resolution of the profile-managed state:
  /// VPN off -> from the current profile config; VPN on -> from the running
  /// core's applied VPN options, flagging any divergence from the config.
  Future<void> _refreshManagedAccess() async {
    final manual = ref.read(vpnSettingProvider).accessControl;
    final isRunning = ref.read(runTimeProvider) != null;
    final profileConfigAccess = globalState.activeProfileAccessControl ??
        await globalState.resolveCurrentProfileSplitTunnelingAccessControl();
    final appliedOptions = isRunning
        ? await productServices.accessControl.readAppliedVpnOptions()
        : null;
    final appliedAccess = productServices.accessControl
        .appliedAccessControlFromOptions(appliedOptions);
    final managed = productServices.accessControl.resolveProfileManagedAccess(
      profileConfigAccessControl: profileConfigAccess,
      appliedAccessControl: appliedAccess,
      isRunning: isRunning,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _editorState = productServices.accessControl.resolveEditorState(
        accessControl: manual,
        profileAccessControl: managed.effectiveAccessControl,
        previousState: _editorStateOrNull,
      );
      _profileManaged = managed.managed;
      _hasDrift = managed.hasDrift;
    });
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
    ref.listen(runTimeProvider, (previous, next) {
      if ((previous != null) != (next != null)) {
        unawaited(_refreshManagedAccess());
      }
    });
    final packages = ref.watch(packagesProvider);
    final filtered = productServices.accessControl.filterPackages(
      packages: packages,
      editorState: _editorState,
    );
    final appLocale = AppLocalizations.of(context);
    final isWhitelist = _editorState.isWhitelist;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _persist();
      },
      child: Column(
        children: [
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
          if (_profileManaged && _hasDrift)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      appLocale.accessControlDriftNote,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onErrorContainer,
                          ),
                    ),
                  ),
                ],
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
