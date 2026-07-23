import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'item.dart';

/// The "Log" tab body: the accumulating reverse-scroll stream of requests fed by
/// requestsProvider. A plain body (no PageMixin) — the merged ConnectionsView owns
/// the app-bar; search/keywords are passed down as [query]/[keywords].
class LogConnectionsBody extends ConsumerStatefulWidget {
  const LogConnectionsBody({
    super.key,
    this.query = '',
    this.keywords = const [],
  });

  final String query;
  final List<String> keywords;

  @override
  ConsumerState<LogConnectionsBody> createState() => _LogConnectionsBodyState();
}

class _LogConnectionsBodyState extends ConsumerState<LogConnectionsBody> {
  late final ValueNotifier<ConnectionsState> _requestsStateNotifier;
  List<Connection> _requests = [];
  final _tag = CacheTag.requests;
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    final preOffset = globalState.cacheScrollPosition[_tag] ?? -1;
    _scrollController = ScrollController(
      initialScrollOffset: preOffset > 0 ? preOffset : double.maxFinite,
    );
    _requests = globalState.appState.requests.list;
    _requestsStateNotifier = ValueNotifier<ConnectionsState>(
      ConnectionsState(
        connections: _requests,
        query: widget.query,
        keywords: widget.keywords,
      ),
    );
    ref.listenManual(
      requestsProvider.select((state) => state.list),
      (prev, next) {
        if (!connectionListEquality.equals(prev, next)) {
          _requests = next;
          updateRequestsThrottler();
        }
      },
    );
  }

  @override
  void didUpdateWidget(LogConnectionsBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query ||
        !listEquals(oldWidget.keywords, widget.keywords)) {
      _requestsStateNotifier.value = _requestsStateNotifier.value.copyWith(
        query: widget.query,
        keywords: widget.keywords,
      );
    }
  }

  // ConnectionRow is a fixed-height row, so the per-item cache is a constant.
  double _calcCacheHeight(Connection item) => kConnRowExtent;

  @override
  void dispose() {
    _requestsStateNotifier.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void updateRequestsThrottler() {
    throttler.call(FunctionTag.requests, () {
      final isEquality = connectionListEquality.equals(
        _requests,
        _requestsStateNotifier.value.connections,
      );
      if (isEquality) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _requestsStateNotifier.value = _requestsStateNotifier.value.copyWith(
            connections: _requests,
          );
        }
      });
    }, duration: commonDuration);
  }

  @override
  Widget build(BuildContext context) => TextScaleNotification(
        child: ValueListenableBuilder<ConnectionsState>(
          valueListenable: _requestsStateNotifier,
          builder: (_, state, __) {
            final connections = state.list;
            final itemCount =
                connections.isEmpty ? 0 : connections.length * 2 - 1;
            final content = connections.isEmpty
                ? NullStatus(
                    label: appLocalizations
                        .nullTip(appLocalizations.connectionsLog),
                  )
                : Align(
                    alignment: Alignment.topCenter,
                    child: ScrollToEndBox(
                      controller: _scrollController,
                      tag: _tag,
                      dataSource: connections,
                      child: CommonScrollBar(
                        controller: _scrollController,
                        child: CacheItemExtentListView(
                          tag: _tag,
                          reverse: true,
                          shrinkWrap: true,
                          physics: const NextClampingScrollPhysics(),
                          controller: _scrollController,
                          itemExtentBuilder: (index) {
                            if (index.isOdd) {
                              return 0;
                            }
                            return _calcCacheHeight(connections[index ~/ 2]);
                          },
                          itemBuilder: (_, index) {
                            if (index.isOdd) {
                              return const Divider(height: 0);
                            }
                            final connection = connections[index ~/ 2];
                            return ConnectionRow(
                              key: Key(connection.id),
                              connection: connection,
                              mode: ConnectionRowMode.log,
                              onClickKeyword: (value) {
                                context.commonScaffoldState?.addKeyword(value);
                              },
                            );
                          },
                          itemCount: itemCount,
                          keyBuilder: (index) {
                            if (index.isOdd) {
                              return "divider";
                            }
                            return connections[index ~/ 2].id;
                          },
                        ),
                      ),
                    ),
                  );
            return FadeBox(
              child: state.loading
                  ? const Center(
                      child: CircularProgressIndicator(),
                    )
                  : content,
            );
          },
        ),
        onNotification: (_) {
          globalState.cacheHeightMap[_tag]?.clear();
        },
      );
}
