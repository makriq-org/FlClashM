part of '../action.dart';

/// What the current profile's panel asks of the settings, stamped with the
/// update that said it, so every refresh says it again.
typedef ProfileHeaderSettings = ({
  String? id,
  DateTime? updatedAt,
  ViewRequest? view,
  List<DashboardWidget>? widgets,
  bool widgetsDenied,
  Set<String>? switches,
  bool globalModeAllowed,
  bool hideIp,
});

ProfileHeaderSettings profileHeaderSettingsOf(Profile? profile) {
  final headers = profile?.headers;
  return (
    id: profile?.id,
    updatedAt: profile?.lastUpdateDate,
    view: headers?.view,
    widgets: headers?.dashboardWidgets,
    widgetsDenied: headers?.widgetEditingDenied ?? false,
    switches: headers?.appSwitches,
    globalModeAllowed: headers?.globalModeAllowed ?? true,
    hideIp: headers?.specials?.contains('hideip') ?? false,
  );
}

@Riverpod(keepAlive: true)
class ProfileHeadersAction extends _$ProfileHeadersAction {
  int _generation = 0;

  @override
  void build() {
    ref.listen(
      currentProfileProvider.select(profileHeaderSettingsOf),
      (_, next) => _applyLater(next),
    );
    _applyLater(null);
  }

  /// Settings may not change inside the flush that reported the profile, so
  /// the latest request is applied once that flush has ended.
  void _applyLater(ProfileHeaderSettings? settings) {
    final generation = ++_generation;
    scheduleMicrotask(() {
      if (generation != _generation || !ref.mounted) {
        return;
      }
      apply(
        settings ?? profileHeaderSettingsOf(ref.read(currentProfileProvider)),
      );
    });
  }

  void apply(ProfileHeaderSettings settings) {
    final appSettings = ref.read(appSettingProvider);
    final owned = appSettings.ownedSettings;
    T? asked<T>(String key, T? value) => owned.contains(key) ? null : value;
    if (settings.view case final view?) {
      ref
          .read(proxiesStyleSettingProvider.notifier)
          .update(
            (state) => state.copyWith(
              type: asked('view.proxies.type', view.type) ?? state.type,
              sortType: asked('view.proxies.sort', view.sort) ?? state.sortType,
              layout: asked('view.proxies.layout', view.layout) ?? state.layout,
              iconStyle:
                  asked('view.proxies.icon', view.icon) ?? state.iconStyle,
              cardType: asked('view.proxies.card', view.card) ?? state.cardType,
              hideTimeoutProxies:
                  asked('view.proxies.hidetimeout', view.hideTimeout) ??
                  state.hideTimeoutProxies,
            ),
          );
      if (view.touchesTheme) {
        final color = asked('view.app.color', view.color);
        ref
            .read(themeSettingProvider.notifier)
            .update(
              (state) => state.copyWith(
                style: asked('view.app.board', view.board) ?? state.style,
                themeMode:
                    asked('view.app.theme', view.themeMode) ?? state.themeMode,
                liquidGlass:
                    asked('view.app.glass', view.liquidGlass) ??
                    state.liquidGlass,
                primaryColor: color ?? state.primaryColor,
                primaryColors:
                    color == null || state.primaryColors.contains(color)
                    ? state.primaryColors
                    : [...state.primaryColors, color],
                colorStyle:
                    asked('view.app.color', view.colorStyle) ??
                    state.colorStyle,
                pureBlack:
                    asked('view.app.black', view.pureBlack) ?? state.pureBlack,
              ),
            );
      }
      if (view.touchesApp) {
        ref
            .read(appSettingProvider.notifier)
            .update(
              (state) => state.copyWith(
                floatingNavigationBar:
                    asked('view.app.navbar', view.floatingNavigationBar) ??
                    state.floatingNavigationBar,
                tabAnimation:
                    asked('view.app.tabs', view.tabAnimation) ??
                    state.tabAnimation,
              ),
            );
      }
    }
    // Cards the user arranged stay put until the panel denies editing them or
    // the user hands the settings back to the subscription.
    if (settings.widgets case final widgets?
        when settings.widgetsDenied ||
            !owned.contains(dashboardWidgetsSetting)) {
      ref
          .read(appSettingProvider.notifier)
          .update((state) => state.copyWith(dashboardWidgets: widgets));
    }
    if (settings.switches case final switches?
        when !appSettings.overrideProviderSettings) {
      bool? said(String flag) => owned.contains(appSwitchSettings[flag])
          ? null
          : switches.contains(flag);
      ref
          .read(appSettingProvider.notifier)
          .update(
            (state) => state.copyWith(
              minimizeOnExit: said('minimize') ?? state.minimizeOnExit,
              autoLaunch: said('autorun') ?? state.autoLaunch,
              silentLaunch: said('shadowstart') ?? state.silentLaunch,
              autoRun: said('autostart') ?? state.autoRun,
              autoCheckUpdate: said('autoupdate') ?? state.autoCheckUpdate,
              openLogs: said('openlogs') ?? state.openLogs,
              closeConnections:
                  said('closeconnections') ?? state.closeConnections,
            ),
          );
    }
    _applySpecial(
      hideIpSetting,
      said: settings.hideIp,
      owned: owned,
      set: (state, {required on}) => state.copyWith(hideIp: on),
    );
    if (!settings.globalModeAllowed &&
        ref.read(patchClashConfigProvider).mode == Mode.global) {
      ref.read(setupActionProvider.notifier).changeMode(Mode.rule);
    }
  }

  /// A special flag sets its setting while the panel sends it, and puts the
  /// default back once the panel drops it, unless the user took it over.
  void _applySpecial(
    String key, {
    required bool said,
    required Set<String> owned,
    required AppSettingProps Function(AppSettingProps state, {required bool on})
    set,
  }) {
    ref.read(appSettingProvider.notifier).update((state) {
      final panelSet = state.panelSetSettings;
      if (said && !owned.contains(key)) {
        return set(
          state,
          on: true,
        ).copyWith(panelSetSettings: {...panelSet, key});
      }
      if (said || !panelSet.contains(key)) {
        return state;
      }
      final cleared = state.copyWith(
        panelSetSettings: {...panelSet}..remove(key),
      );
      return owned.contains(key) ? cleared : set(cleared, on: false);
    });
  }
}
