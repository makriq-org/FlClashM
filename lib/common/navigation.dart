import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/views/views.dart';
import 'package:flutter/material.dart';

class Navigation {

  factory Navigation() {
    _instance ??= Navigation._internal();
    return _instance!;
  }

  Navigation._internal();
  static Navigation? _instance;

  List<NavigationItem> getItems({
    bool openLogs = false,
    bool hasProxies = false,
  }) => [
      const NavigationItem(
        keep: false,
        icon: Icon(Icons.home_rounded),
        label: PageLabel.dashboard,
        view: DashboardView(
          key: GlobalObjectKey(PageLabel.dashboard),
        ),
      ),
      NavigationItem(
        icon: const Icon(Icons.travel_explore_rounded),
        label: PageLabel.proxies,
        view: const ProxiesView(
          key: GlobalObjectKey(
            PageLabel.proxies,
          ),
        ),
        modes: hasProxies
            ? [NavigationItemMode.mobile, NavigationItemMode.desktop]
            : [],
      ),
      const NavigationItem(
        icon: Icon(Icons.account_circle_rounded),
        label: PageLabel.profiles,
        view: ProfilesView(
          key: GlobalObjectKey(
            PageLabel.profiles,
          ),
        ),
      ),
      const NavigationItem(
        icon: Icon(Icons.swap_horiz_rounded),
        label: PageLabel.connections,
        view: ConnectionsView(
          key: GlobalObjectKey(
            PageLabel.connections,
          ),
        ),
        description: "connectionsDesc",
        modes: [NavigationItemMode.desktop, NavigationItemMode.more],
      ),
      const NavigationItem(
        icon: Icon(Icons.storage),
        label: PageLabel.resources,
        description: "resourcesDesc",
        view: ResourcesView(
          key: GlobalObjectKey(
            PageLabel.resources,
          ),
        ),
        modes: [NavigationItemMode.more],
      ),
      NavigationItem(
        icon: const Icon(Icons.adb),
        label: PageLabel.logs,
        view: const LogsView(
          key: GlobalObjectKey(
            PageLabel.logs,
          ),
        ),
        description: "logsDesc",
        modes: openLogs
            ? [NavigationItemMode.desktop, NavigationItemMode.more]
            : [],
      ),
      const NavigationItem(
        icon: Icon(Icons.settings_rounded),
        label: PageLabel.tools,
        view: ToolsView(
          key: GlobalObjectKey(
            PageLabel.tools,
          ),
        ),
        modes: [NavigationItemMode.desktop, NavigationItemMode.mobile],
      ),
    ];
}

final navigation = Navigation();
