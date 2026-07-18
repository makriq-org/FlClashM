import 'package:flclashx/common/common.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'card.dart';
import 'common.dart';

class ProxiesTabView extends ConsumerStatefulWidget {
  const ProxiesTabView({super.key});

  @override
  ConsumerState<ProxiesTabView> createState() => ProxiesTabViewState();
}

class ProxiesTabViewState extends ConsumerState<ProxiesTabView>
    with TickerProviderStateMixin {
  TabController? _tabController;
  final _hasMoreButtonNotifier = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    _handleTabListen();
  }

  @override
  void dispose() {
    _destroyTabController();
    super.dispose();
  }

  Consumer _buildMoreButton() => Consumer(
      builder: (_, ref, ___) {
        final isMobileView = ref.watch(isMobileViewProvider);
        return IconButton(
          onPressed: _showMoreMenu,
          icon: isMobileView
              ? const Icon(
                  Icons.expand_more,
                )
              : const Icon(
                  Icons.chevron_right,
                ),
        );
      },
    );

  void _showMoreMenu() {
    showSheet(
      context: context,
      props: const SheetProps(
        isScrollControlled: false,
      ),
      builder: (_, type) => AdaptiveSheetScaffold(
          type: type,
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Consumer(
              builder: (_, ref, __) {
                final state = ref.watch(proxiesSelectorStateProvider);
                return SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    runSpacing: 8,
                    spacing: 8,
                    children: [
                      for (final groupName in state.groupNames)
                        SettingTextCard(
                          groupName,
                          onPressed: () {
                            final index = state.groupNames.indexWhere(
                              (item) => item == groupName,
                            );
                            if (index == -1) return;
                            _tabController?.animateTo(index);
                            globalState.appController
                                .updateCurrentGroupName(groupName);
                            Navigator.of(context).pop();
                          },
                          isSelected: groupName == state.currentGroupName,
                        )
                    ],
                  ),
                );
              },
            ),
          ),
          title: appLocalizations.proxyGroup,
        ),
    );
  }

  void _tabControllerListener([int? index]) {
    var groupIndex = index;
    if (groupIndex == -1) {
      return;
    }
    final appController = globalState.appController;
    if (groupIndex == null) {
      final currentIndex = _tabController?.index;
      groupIndex = currentIndex;
    }
    final currentGroups = appController.getCurrentGroups();
    if (groupIndex == null || groupIndex >= currentGroups.length) {
      return;
    }
    final currentGroup = currentGroups[groupIndex];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      globalState.appController.updateCurrentGroupName(
        currentGroup.name,
      );
    });
  }

  void _destroyTabController() {
    _tabController?.removeListener(_tabControllerListener);
    _tabController?.dispose();
    _tabController = null;
  }

  void _updateTabController(int length, int index) {
    if (length == 0) {
      _destroyTabController();
      return;
    }
    final realIndex = index == -1 ? 0 : index;
    _tabController ??= TabController(
      length: length,
      initialIndex: realIndex,
      vsync: this,
    );
    _tabControllerListener(realIndex);
    _tabController?.addListener(_tabControllerListener);
  }

  void _handleTabListen() {
    ref.listenManual(
      proxiesSelectorStateProvider,
      (prev, next) {
        if (prev == next) {
          return;
        }
        if (!stringListEquality.equals(prev?.groupNames, next.groupNames)) {
          _destroyTabController();
          final index = next.groupNames.indexWhere(
            (item) => item == next.currentGroupName,
          );
          _updateTabController(next.groupNames.length, index);
        }
      },
      fireImmediately: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(themeSettingProvider.select((state) => state.textScale));
    final state = ref.watch(groupNamesStateProvider);
    final groupNames = state.groupNames;
    if (groupNames.isEmpty) {
      return NullStatus(
        label: appLocalizations.nullTip(appLocalizations.proxies),
      );
    }
    final children = groupNames.map((groupName) => KeepScope(
        child: ProxyGroupView(
          key: ValueKey(groupName),
          groupName: groupName,
        ),
      )).toList();
    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (scrollNotification) {
            _hasMoreButtonNotifier.value =
                scrollNotification.metrics.maxScrollExtent > 0;
            return true;
          },
          child: ValueListenableBuilder(
            valueListenable: _hasMoreButtonNotifier,
            builder: (_, value, child) => Stack(
                alignment: AlignmentDirectional.centerStart,
                children: [
                  TabBar(
                    controller: _tabController,
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 16 + (value ? 16 : 0),
                    ),
                    dividerColor: Colors.transparent,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    overlayColor:
                        const WidgetStatePropertyAll(Colors.transparent),
                    tabs: [
                      for (final groupName in groupNames)
                        Tab(
                          text: groupName,
                        ),
                    ],
                  ),
                  if (value)
                    Positioned(
                      right: 0,
                      child: child!,
                    ),
                ],
              ),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      context.colorScheme.surface.opacity10,
                      context.colorScheme.surface,
                    ],
                    stops: const [
                      0.0,
                      0.1
                    ]),
              ),
              child: _buildMoreButton(),
            ),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: children,
          ),
        )
      ],
    );
  }
}

class ProxyGroupView extends ConsumerStatefulWidget {

  const ProxyGroupView({
    super.key,
    required this.groupName,
  });
  final String groupName;

  @override
  ConsumerState<ProxyGroupView> createState() => ProxyGroupViewState();
}

class ProxyGroupViewState extends ConsumerState<ProxyGroupView> {
  final _controller = ScrollController();

  String get groupName => widget.groupName;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(proxyGroupSelectorStateProvider(groupName));
    final proxies = state.proxies;
    final columns = state.columns;
    final proxyCardType = state.proxyCardType;
    final sortedProxies = globalState.appController.getSortProxies(
      proxies,
      state.testUrl,
    );
    return Align(
      alignment: Alignment.topCenter,
      child: CommonAutoHiddenScrollBar(
        controller: _controller,
        child: GridView.builder(
          controller: _controller,
          padding: const EdgeInsets.only(
            top: 16,
            left: 16,
            right: 16,
            bottom: 96,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            mainAxisExtent: getItemHeight(proxyCardType),
          ),
          itemCount: sortedProxies.length,
          itemBuilder: (_, index) {
            final proxy = sortedProxies[index];
            return ProxyCard(
              testUrl: state.testUrl,
              groupType: state.groupType,
              type: proxyCardType,
              key: ValueKey('$groupName.${proxy.name}'),
              proxy: proxy,
              groupName: groupName,
            );
          },
        ),
      ),
    );
  }
}
