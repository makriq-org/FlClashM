import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/ui/ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connections.dart';
import 'requests.dart';

/// Recent requests and live connections as one page: its title names the feed
/// on screen and opens a menu that switches to the other.
///
/// Both feeds stay mounted once shown, so the list, its scroll position and a
/// paused follow survive a look at the other one. The hidden feed sits in an
/// inactive [PageActivityScope] with tickers off, which also stops the live
/// feed from polling the Core while it is not on screen.
class ConnectionFeedsView extends ConsumerStatefulWidget {
  const ConnectionFeedsView({super.key});

  @override
  ConsumerState<ConnectionFeedsView> createState() =>
      _ConnectionFeedsViewState();
}

class _ConnectionFeedsViewState extends ConsumerState<ConnectionFeedsView> {
  final _shown = <RequestFeed>{};

  List<CommonPopupMenuItem> _titleMenuItems(RequestFeed feed) {
    final appLocalizations = context.appLocalizations;
    return [
      for (final (option, label) in [
        (RequestFeed.recent, appLocalizations.recentRequests),
        (RequestFeed.live, appLocalizations.liveConnections),
      ])
        CommonPopupMenuItem(
          label: label,
          checked: option == feed,
          onPressed: () => ref
              .read(appSettingProvider.notifier)
              .update((state) => state.copyWith(requestFeed: option)),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(
      appSettingProvider.select((state) => state.requestFeed),
    );
    _shown.add(feed);
    final pageActive = PageActivityScope.isActiveOf(context);
    final titleMenuItems = _titleMenuItems(feed);
    return IndexedStack(
      index: feed.index,
      children: [
        for (final option in RequestFeed.values)
          if (!_shown.contains(option))
            const SizedBox.shrink()
          else
            PageActivityScope(
              isActive: pageActive && option == feed,
              child: TickerMode(
                enabled: option == feed,
                child: ExcludeFocus(
                  excluding: option != feed,
                  child: switch (option) {
                    RequestFeed.recent => RequestsView(
                      titleMenuItems: titleMenuItems,
                    ),
                    RequestFeed.live => ConnectionsView(
                      titleMenuItems: titleMenuItems,
                    ),
                  },
                ),
              ),
            ),
      ],
    );
  }
}
