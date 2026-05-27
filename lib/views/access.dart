import 'dart:async';

import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/l10n/l10n.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/plugins/app.dart';
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
  final _loadCompleter = Completer();

  String _query = '';
  bool _showSystem = false;
  bool _showNoInternet = false;
  bool _enabled = false;
  AccessControlMode _mode = AccessControlMode.rejectSelected;

  late Set<String> _selectedSet;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final ac = ref.read(vpnSettingProvider).accessControl;
    _mode = ac.mode;
    _selectedSet = Set.from(ac.currentList);
    _enabled = ac.enable;
    _showSystem = !ac.isFilterSystemApp;
    _showNoInternet = !ac.isFilterNonInternetApp;
    _loadCompleter.complete(globalState.appController.getPackages());
  }

  @override
  void dispose() {
    _persist();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _persist() {
    if (!_dirty) return;
    final notifier = ref.read(vpnSettingProvider.notifier);
    notifier.updateState(
      (state) => state.copyWith.accessControl(
        enable: _enabled,
        acceptList: _mode == AccessControlMode.acceptSelected
            ? _selectedSet.toList()
            : [],
        rejectList: _mode == AccessControlMode.rejectSelected
            ? _selectedSet.toList()
            : [],
        mode: _mode,
        isFilterSystemApp: !_showSystem,
        isFilterNonInternetApp: !_showNoInternet,
      ),
    );
  }

  void _toggleApp(String pkg) {
    setState(() {
      _dirty = true;
      if (_selectedSet.contains(pkg)) {
        _selectedSet.remove(pkg);
      } else {
        _selectedSet.add(pkg);
      }
    });
  }

  void _switchMode() {
    setState(() {
      _dirty = true;
      _mode = _mode == AccessControlMode.acceptSelected
          ? AccessControlMode.rejectSelected
          : AccessControlMode.acceptSelected;
      _selectedSet.clear();
    });
  }

  List<Package> _filter(List<Package> packages) {
    final q = _query.toLowerCase();
    return packages.where((p) {
      if (!_showSystem && p.system) return false;
      if (!_showNoInternet && !p.internet) return false;
      if (q.isNotEmpty &&
          !p.label.toLowerCase().contains(q) &&
          !p.packageName.toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        final sa = _selectedSet.contains(a.packageName) ? 0 : 1;
        final sb = _selectedSet.contains(b.packageName) ? 0 : 1;
        final c = sa.compareTo(sb);
        return c != 0 ? c : a.label.compareTo(b.label);
      });
  }

  void _showModeHelp() {
    final appLocale = AppLocalizations.of(context);
    final title = _mode == AccessControlMode.acceptSelected
        ? appLocale.includeInVpn
        : appLocale.excludeFromVpn;
    final desc = _mode == AccessControlMode.acceptSelected
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
    final packages = ref.watch(packagesProvider);
    final filtered = _filter(packages);
    final appLocale = AppLocalizations.of(context);
    final isWhitelist = _mode == AccessControlMode.acceptSelected;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _persist();
      },
      child: Column(
        children: [
          ListItem.switchItem(
            title: Text(appLocale.appAccessControl),
            delegate: SwitchDelegate(
              value: _enabled,
              onChanged: (v) => setState(() {
                _enabled = v;
                _dirty = true;
              }),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: DisabledMask(
              status: !_enabled,
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
                        selected: {_mode},
                        onSelectionChanged: (_) => _switchMode(),
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
                        suffixIcon: _query.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _query = '');
                                },
                              )
                            : null,
                      ),
                      onChanged: (v) => setState(() => _query = v),
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
                          isSelected: _showSystem,
                          onPressed: () => setState(() {
                            _showSystem = !_showSystem;
                            _dirty = true;
                          }),
                        ),
                        IconButton(
                          icon: const Icon(Icons.wifi_off),
                          tooltip: appLocale.noNetworkApp,
                          isSelected: _showNoInternet,
                          onPressed: () => setState(() {
                            _showNoInternet = !_showNoInternet;
                            _dirty = true;
                          }),
                        ),
                        const Spacer(),
                        if (_selectedSet.isNotEmpty)
                          TextButton.icon(
                            icon: const Icon(Icons.clear_all, size: 18),
                            label: Text('${_selectedSet.length}'),
                            onPressed: () => setState(() {
                              _selectedSet.clear();
                              _dirty = true;
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
                            final selected =
                                _selectedSet.contains(pkg.packageName);
                            return _AppTile(
                              package: pkg,
                              selected: selected,
                              isWhitelist: isWhitelist,
                              onTap: () => _toggleApp(pkg.packageName),
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
  final VoidCallback onTap;

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
                future: app?.getPackageIcon(package.packageName),
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
