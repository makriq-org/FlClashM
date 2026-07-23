import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/app.dart';
import 'package:flclashx/providers/config.dart';
import 'package:flclashx/providers/state.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'card.dart';
import 'common.dart';

class ProxiesListView extends StatefulWidget {
  const ProxiesListView({super.key});

  @override
  State<ProxiesListView> createState() => _ProxiesListViewState();
}

class _ProxiesListViewState extends State<ProxiesListView> {
  final _controller = ScrollController();

  int _lastGroupsVersion = 0;
  List<String> _lastGroupNames = [];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<Widget> _buildItems(
    WidgetRef ref, {
    required List<String> groupNames,
    required int columns,
    required ProxyCardType type,
    required String query,
  }) {
    final items = <Widget>[];
    for (final groupName in groupNames) {
      final group = ref.watch(
        groupsProvider.select(
          (state) => state.getGroup(groupName),
        ),
      );
      if (group == null) {
        continue;
      }
      items.add(
        ProxyGroupCard(
          key: ValueKey(groupName),
          group: group,
          columns: columns,
          type: type,
          query: query,
        ),
      );
    }
    return items;
  }

  @override
  Widget build(BuildContext context) => Consumer(
      builder: (_, ref, __) {
        final state = ref.watch(proxiesListSelectorStateProvider);

        final groupsVersion = ref.watch(versionProvider);

        ref.watch(themeSettingProvider.select((state) => state.textScale));

        if (_lastGroupsVersion != groupsVersion ||
            !listEquals(_lastGroupNames, state.groupNames)) {
          _lastGroupsVersion = groupsVersion;
          _lastGroupNames = state.groupNames;

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {});
            }
          });
        }

        if (state.groupNames.isEmpty) {
          return NullStatus(
            label: appLocalizations.nullTip(appLocalizations.proxies),
          );
        }
        final items = _buildItems(
          ref,
          groupNames: state.groupNames,
          columns: state.columns,
          type: state.proxyCardType,
          query: state.query,
        );
        return RepaintBoundary(
          child: CommonScrollBar(
            controller: _controller,
            child: Stack(
              children: [
              Positioned.fill(
                child: ScrollConfiguration(
                  behavior: HiddenBarScrollBehavior(),
                  child: FocusTraversalGroup(
                    policy: WidgetOrderTraversalPolicy(),
                    child: ListView.builder(
                      padding: const EdgeInsets.all(16),
                      controller: _controller,
                      itemCount: items.length,
                      itemBuilder: (_, index) => items[index],
                    ),
                  ),
                ),
              ),
              ],
            ),
          ),
        );
      },
    );
}

class ProxyGroupCard extends StatefulWidget {

  const ProxyGroupCard({
    super.key,
    required this.group,
    required this.columns,
    required this.type,
    required this.query,
  });
  final Group group;
  final int columns;
  final ProxyCardType type;
  final String query;

  @override
  State<ProxyGroupCard> createState() => _ProxyGroupCardState();
}

class _ProxyGroupCardState extends State<ProxyGroupCard> {
  final _expansibleController = ExpansibleController();

  bool isLock = false;
  bool _bodyMounted = false;
  late List<Proxy> _sortedProxies;

  String get icon => widget.group.icon;

  String get groupName => widget.group.name;

  bool get isExpand => _expansibleController.isExpanded;

  List<Proxy> _resolveProxies() =>
      globalState.appController.getSortProxies(
        widget.group.all
            .where(
              (item) => item.name.toLowerCase().contains(widget.query),
            )
            .toList(),
        widget.group.testUrl,
      );

  @override
  void initState() {
    super.initState();
    _sortedProxies = _resolveProxies();
  }

  @override
  void didUpdateWidget(ProxyGroupCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group != widget.group ||
        oldWidget.query != widget.query) {
      _sortedProxies = _resolveProxies();
    }
  }

  void _collapseAndReleaseBody() {
    _expansibleController.collapse();
    Future<void>.delayed(kThemeAnimationDuration, () {
      if (mounted && !_expansibleController.isExpanded) {
        setState(() => _bodyMounted = false);
      }
    });
  }

  @override
  void dispose() {
    _expansibleController.dispose();
    super.dispose();
  }

  void _toggleExpansion(Set<String> currentUnfoldSet) {
    final appController = globalState.appController;
    final unfoldSet = Set<String>.from(currentUnfoldSet);
    
    if (_expansibleController.isExpanded) {
      _collapseAndReleaseBody();
      unfoldSet.remove(groupName);
    } else {
      setState(() => _bodyMounted = true);
      _expansibleController.expand();
      unfoldSet.add(groupName);
    }
    appController.updateCurrentUnfoldSet(unfoldSet);
  }

  Future<void> _delayTest() async {
    if (isLock) return;
    isLock = true;
    await delayTest(
      widget.group.all,
      widget.group.testUrl,
    );
    isLock = false;
  }

  Widget _buildIcon() => Consumer(
      builder: (_, ref, child) {
        final iconStyle = ref.watch(
          proxiesStyleSettingProvider.select(
            (state) => state.iconStyle,
          ),
        );
        final icon = ref.watch(proxiesStyleSettingProvider.select((state) {
          final iconMapEntryList = state.iconMap.entries.toList();
          final index = iconMapEntryList.indexWhere((item) {
            try {
              return RegExp(item.key).hasMatch(groupName);
            } catch (_) {
              return false;
            }
          });
          if (index != -1) {
            return iconMapEntryList[index].value;
          }
          return this.icon;
        }));
        return switch (iconStyle) {
          ProxiesIconStyle.icon => Container(
              margin: const EdgeInsets.only(
                right: 16,
              ),
              child: LayoutBuilder(
                builder: (_, constraints) => CommonTargetIcon(
                    src: icon,
                    size: 38,
                  ),
              ),
            ),
          ProxiesIconStyle.none => Container(),
        };
      },
    );

  List<Widget> _buildProxyRows() => _sortedProxies
      .chunks(widget.columns)
      .map<Widget>((proxies) {
        final children = proxies
            .map<Widget>(
              (proxy) => Flexible(
                flex: 1,
                child: RepaintBoundary(
                  child: ProxyCard(
                    testUrl: widget.group.testUrl,
                    type: widget.type,
                    groupType: widget.group.type,
                    key: ValueKey('$groupName.${proxy.name}'),
                    proxy: proxy,
                    groupName: groupName,
                  ),
                ),
              ),
            )
            .fill(
              widget.columns,
              filler: (_) => const Flexible(child: SizedBox()),
            )
            .separated(const SizedBox(width: 8));
        return Row(children: children.toList());
      })
      .separated(
        SizedBox(
          height: widget.type == ProxyCardType.oneline ? 4 : 8,
        ),
      )
      .toList();

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return Consumer(
      builder: (_, ref, __) {
        final unfoldSet = ref.watch(unfoldSetProvider);
        final shouldExpand = unfoldSet.contains(groupName);
        final mountBody = _bodyMounted || shouldExpand;
        
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (shouldExpand && !_expansibleController.isExpanded) {
            _bodyMounted = true;
            _expansibleController.expand();
          } else if (!shouldExpand && _expansibleController.isExpanded) {
            _collapseAndReleaseBody();
          }
        });
        
        return RepaintBoundary(
          // No per-group FocusTraversalGroup: wrapping each card in its own
          // traversal group made every group a membrane the D-pad had to step
          // out of and back into, costing an extra press to cross between groups.
          // The whole list shares the outer group (ProxiesListView), so
          // directional nav flows straight through; ExcludeFocus still keeps a
          // folded group's hidden proxies out of the traversal.
          child: Expansible(
              controller: _expansibleController,
              headerBuilder: (context, animation) => GestureDetector(
                onTap: () => _toggleExpansion(unfoldSet),
                child: Container(
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerLow.opacity80,
                    borderRadius: BorderRadius.circular(16.0),
                  ),
                  margin: const EdgeInsets.symmetric(vertical: 4.0),
                  padding: const EdgeInsets.symmetric(
                    vertical: 10.0,
                    horizontal: 16.0,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Row(
                          children: [
                            _buildIcon(),
                            Flexible(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    groupName,
                                    style: context.textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  Flexible(
                                    flex: 1,
                                    child: Consumer(
                                      builder: (_, ref, __) {
                                        final proxyName = ref
                                            .watch(getSelectedProxyNameProvider(groupName))
                                            .getSafeValue("");
                                        if (proxyName.isEmpty) {
                                          return const SizedBox.shrink();
                                        }
                                        return EmojiText(
                                          overflow: TextOverflow.ellipsis,
                                          proxyName,
                                          style: context.textTheme.labelMedium?.toLight,
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Row(
                        children: [
                          // Ping the whole group straight from the header —
                          // available while collapsed too (previously expand-only),
                          // which also gives the TV D-pad a focus target on a
                          // folded group.
                          //
                          // Both header buttons share the exact same box so their
                          // top/bottom edges line up. With a D-pad, a vertical press
                          // then can't land on the horizontal sibling (which had a
                          // taller filled-tonal box), so up/down moves straight to
                          // the next/previous group in one press; left/right switches
                          // between ping and expand within the group.
                          IconButton(
                            onPressed: _delayTest,
                            padding: EdgeInsets.zero,
                            constraints:
                                const BoxConstraints.tightFor(width: 40, height: 40),
                            icon: const Icon(Icons.network_ping),
                          ),
                          const SizedBox(width: 6),
                          IconButton.filledTonal(
                            onPressed: () => _toggleExpansion(unfoldSet),
                            padding: EdgeInsets.zero,
                            constraints:
                                const BoxConstraints.tightFor(width: 40, height: 40),
                            icon: CommonExpandIcon(expand: isExpand),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              bodyBuilder: (context, animation) => ExcludeFocus(
                // A collapsed group keeps its proxy cards mounted — SizeTransition
                // only clips them to zero height — and every card is a focusable
                // OutlinedButton. On Android TV the D-pad would otherwise dive into
                // these invisible cards, so the highlight jitters and looks like it
                // skips whole groups. Drop the folded body from focus traversal.
                excluding: !shouldExpand,
                child: RepaintBoundary(
                  child: SizeTransition(
                    sizeFactor: animation,
                    axisAlignment: -1.0,
                    child: FadeTransition(
                      opacity: animation,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4.0),
                        child: Column(
                          children:
                              mountBody ? _buildProxyRows() : const [],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              expansibleBuilder: (context, header, body, animation) =>
                  Column(children: [header, body]),
            ),
        );
      },
    );
  }
}
