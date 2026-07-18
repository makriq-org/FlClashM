import 'dart:async';

import 'package:flclashx/clash/clash.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/views/zashboard.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'item.dart';
import 'requests.dart';

enum _ConnTab { active, log }

/// The merged "Connections" page: one nav entry hosting an Active/Log segmented
/// switch over an IndexedStack of the two bodies. Owns the shared app-bar (actions,
/// search, keyword chips) and routes the close-all action to the Active tab only.
class ConnectionsView extends ConsumerStatefulWidget {
  const ConnectionsView({super.key});

  @override
  ConsumerState<ConnectionsView> createState() => _ConnectionsViewState();
}

class _ConnectionsViewState extends ConsumerState<ConnectionsView>
    with PageMixin {
  _ConnTab _tab = _ConnTab.active;
  String _query = '';
  List<String> _keywords = const [];

  @override
  List<Widget> get actions => [
        if (_tab == _ConnTab.active)
          IconButton(
            onPressed: () {
              clashCore.closeConnections();
            },
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        // Placed last so it sits to the right of the search button (default order).
        const _ZashboardButton(),
      ];

  @override
  Null Function(String value) get onSearch => (value) {
        setState(() {
          _query = value;
        });
      };

  @override
  Null Function(List<String> keywords) get onKeywordsUpdate => (keywords) {
        setState(() {
          _keywords = keywords;
        });
      };

  @override
  void initState() {
    super.initState();
    ref.listenManual(
      isCurrentPageProvider(
        PageLabel.connections,
        handler: (pageLabel, viewMode) =>
            pageLabel == PageLabel.tools && viewMode == ViewMode.mobile,
      ),
      (prev, next) {
        if (prev != next && next == true) {
          initPageState();
        }
      },
      fireImmediately: true,
    );
  }

  void _selectTab(_ConnTab tab) {
    if (_tab == tab) return;
    setState(() => _tab = tab);
    // Re-push the app-bar so the close-all action appears/disappears with the tab.
    initPageState();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: Center(
            child: CommonTabBar<_ConnTab>(
              groupValue: _tab,
              thumbColor: context.colorScheme.surface,
              backgroundColor: context.colorScheme.surfaceContainerHighest,
              onValueChanged: (value) {
                if (value != null) _selectTab(value);
              },
              children: {
                _ConnTab.active: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(appLocalizations.connectionsActive),
                ),
                _ConnTab.log: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(appLocalizations.connectionsLog),
                ),
              },
            ),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _tab.index,
            children: [
              ActiveConnectionsBody(
                query: _query,
                keywords: _keywords,
                active: _tab == _ConnTab.active,
              ),
              LogConnectionsBody(
                query: _query,
                keywords: _keywords,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Opens zashboard pointed at this client's external-controller — in the
/// built-in webview or the external browser, per the zashboardInApp setting.
/// URL building lives in [buildZashboardUrl].
class _ZashboardButton extends ConsumerWidget {
  const _ZashboardButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inApp = ref.watch(
      appSettingProvider.select((state) => state.zashboardInApp),
    );
    return IconButton(
      tooltip: 'zashboard',
      onPressed: () => openZashboard(context, inApp: inApp),
      icon: SvgPicture.asset(
        'assets/images/icons/zashboard.svg',
        width: 20,
        height: 20,
        // Match the other app-bar icons (muted) rather than render pure white.
        colorFilter: ColorFilter.mode(
          context.colorScheme.onSurfaceVariant,
          BlendMode.srcIn,
        ),
      ),
    );
  }
}

/// The "Active" tab body: a 2s snapshot poll of live connections (gated on the page
/// being current AND this tab selected), with per-row block. Plain body — the parent
/// owns the app-bar; search/keywords arrive as [query]/[keywords].
class ActiveConnectionsBody extends ConsumerStatefulWidget {
  const ActiveConnectionsBody({
    super.key,
    required this.query,
    required this.keywords,
    required this.active,
  });

  final String query;
  final List<String> keywords;
  final bool active;

  @override
  ConsumerState<ActiveConnectionsBody> createState() =>
      _ActiveConnectionsBodyState();
}

class _ActiveConnectionsBodyState extends ConsumerState<ActiveConnectionsBody>
    with WidgetsBindingObserver {
  final _connectionsStateNotifier = ValueNotifier<ConnectionsState>(
    const ConnectionsState(),
  );
  final ScrollController _scrollController = ScrollController(
    keepScrollOffset: false,
  );

  Timer? timer;
  bool _isPageVisible = false;

  bool get _shouldPoll => widget.active && _isPageVisible;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connectionsStateNotifier.value = _connectionsStateNotifier.value.copyWith(
      query: widget.query,
      keywords: widget.keywords,
    );
    ref.listenManual(
      isCurrentPageProvider(
        PageLabel.connections,
        handler: (pageLabel, viewMode) =>
            pageLabel == PageLabel.tools && viewMode == ViewMode.mobile,
      ),
      (prev, next) {
        _isPageVisible = next == true;
        _syncPolling();
      },
      fireImmediately: true,
    );
  }

  @override
  void didUpdateWidget(ActiveConnectionsBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query ||
        !listEquals(oldWidget.keywords, widget.keywords)) {
      _connectionsStateNotifier.value = _connectionsStateNotifier.value.copyWith(
        query: widget.query,
        keywords: widget.keywords,
      );
    }
    if (oldWidget.active != widget.active) {
      _syncPolling();
    }
  }

  void _syncPolling() {
    timer?.cancel();
    timer = null;
    if (_shouldPoll) {
      _updateConnections();
    }
  }

  Future<void> _updateConnections() async {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted && _shouldPoll) {
        _connectionsStateNotifier.value =
            _connectionsStateNotifier.value.copyWith(
          connections: await clashCore.getConnections(),
        );
        timer = Timer(const Duration(seconds: 2), () async {
          _updateConnections();
        });
      }
    });
  }

  Future<void> _handleBlockConnection(String id) async {
    clashCore.closeConnection(id);
    if (!mounted) return;
    _connectionsStateNotifier.value = _connectionsStateNotifier.value.copyWith(
      connections: await clashCore.getConnections(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Don't keep polling getConnections() every 2s while the app is backgrounded.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      timer?.cancel();
      timer = null;
    } else if (state == AppLifecycleState.resumed) {
      _syncPolling();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    _connectionsStateNotifier.dispose();
    _scrollController.dispose();
    timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<ConnectionsState>(
        valueListenable: _connectionsStateNotifier,
        builder: (_, state, __) {
          final connections = state.list;
          if (connections.isEmpty) {
            return NullStatus(
              label: appLocalizations
                  .nullTip(appLocalizations.connectionsActive),
            );
          }
          return CommonScrollBar(
            controller: _scrollController,
            child: ListView.separated(
              controller: _scrollController,
              itemBuilder: (_, index) {
                final connection = connections[index];
                return ConnectionRow(
                  key: Key(connection.id),
                  connection: connection,
                  onClickKeyword: (value) {
                    context.commonScaffoldState?.addKeyword(value);
                  },
                  onBlock: () {
                    _handleBlockConnection(connection.id);
                  },
                );
              },
              separatorBuilder: (context, index) => const Divider(
                height: 0,
              ),
              itemCount: connections.length,
            ),
          );
        },
      );
}
