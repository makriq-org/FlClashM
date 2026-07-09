import 'dart:io';

import 'package:flclashx/clash/core.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/common/yaml_dump.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/l10n/l10n.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/pages/editor.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/views/about.dart';
import 'package:flclashx/views/access.dart';
import 'package:flclashx/views/application_setting.dart';
import 'package:flclashx/views/config/config.dart';
import 'package:flclashx/views/hotkey.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' show dirname, join;
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

import 'backup_and_recovery.dart';
import 'developer.dart';
import 'theme.dart';

class ToolsView extends ConsumerStatefulWidget {
  const ToolsView({super.key});

  @override
  ConsumerState<ToolsView> createState() => _ToolboxViewState();
}

class _ToolboxViewState extends ConsumerState<ToolsView> {
  ListItem<dynamic> _buildNavigationMenuItem(NavigationItem navigationItem) => ListItem.open(
      leading: navigationItem.icon,
      title: Text(Intl.message(navigationItem.label.name)),
      subtitle: navigationItem.description != null
          ? Text(Intl.message(navigationItem.description!))
          : null,
      delegate: OpenDelegate(
        title: Intl.message(navigationItem.label.name),
        widget: navigationItem.view,
      ),
    );

  Widget _buildNavigationMenu(List<NavigationItem> navigationItems) => Column(
      children: [
        for (final navigationItem in navigationItems) ...[
          _buildNavigationMenuItem(navigationItem),
          navigationItems.last != navigationItem
              ? const Divider(
                  height: 0,
                )
              : Container(),
        ]
      ],
    );

  List<Widget> _getOtherList(BuildContext context, bool enableDeveloperMode) => generateSection(
      title: AppLocalizations.of(context).other,
      items: [
        const _RuntimeConfigItem(),
        const _DisclaimerItem(),
        if (enableDeveloperMode) const _DeveloperItem(),
        const _InfoItem(),
        const _CoreStatusItem(),
      ],
    );

  List<Widget> _getSettingList(BuildContext context) => generateSection(
      title: AppLocalizations.of(context).settings,
      items: [
        const _LocaleItem(),
        const _ThemeItem(),
        const _BackupItem(),
        if (system.isDesktop) const _HotkeyItem(),
        if (Platform.isWindows) const _LoopbackItem(),
        if (Platform.isAndroid) const _AccessItem(),
        const _ConfigItem(),
        const _SettingItem(),
      ],
    );

  @override
  Widget build(BuildContext context) {
    final vm2 = ref.watch(
      appSettingProvider.select(
        (state) => VM2(a: state.locale, b: state.developerMode),
      ),
    );
    final appLocale = AppLocalizations.of(context);
    final items = [
      Consumer(
        builder: (_, ref, __) {
          final state = ref.watch(moreToolsSelectorStateProvider);
          if (state.navigationItems.isEmpty) {
            return Container();
          }
          return Column(
            children: [
              ListHeader(title: appLocale.more),
              _buildNavigationMenu(state.navigationItems)
            ],
          );
        },
      ),
      ..._getSettingList(context),
      ..._getOtherList(context, vm2.b),
    ];
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (_, index) => items[index],
      padding: const EdgeInsets.only(bottom: 20),
    );
  }
}

class _LocaleItem extends ConsumerWidget {
  const _LocaleItem();

  String _getLocaleString(BuildContext context, Locale? locale) {
    if (locale == null) return AppLocalizations.of(context).defaultText;
    return Intl.message(locale.toString());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocale = AppLocalizations.of(context);
    final locale =
        ref.watch(appSettingProvider.select((state) => state.locale));
    final subTitle = locale ?? appLocale.defaultText;
    final currentLocale = utils.getLocaleForString(locale);
    return ListItem<Locale?>.options(
      leading: const Icon(Icons.language_outlined),
      title: Text(appLocale.language),
      subtitle: Text(Intl.message(subTitle)),
      delegate: OptionsDelegate(
        title: appLocale.language,
        options: [null, ...AppLocalizations.delegate.supportedLocales],
        onChanged: (locale) {
          ref.read(appSettingProvider.notifier).updateState(
                (state) => state.copyWith(locale: locale?.toString()),
              );
        },
        textBuilder: (locale) => _getLocaleString(context, locale),
        value: currentLocale,
      ),
    );
  }
}

class _ThemeItem extends StatelessWidget {
  const _ThemeItem();

  @override
  Widget build(BuildContext context) {
    final appLocale = AppLocalizations.of(context);
    return ListItem.open(
      leading: const Icon(Icons.style),
      title: Text(appLocale.theme),
      subtitle: Text(appLocale.themeDesc),
      delegate: OpenDelegate(
        title: appLocale.theme,
        widget: const ThemeView(),
      ),
    );
  }
}

class _BackupItem extends StatelessWidget {
  const _BackupItem();

  @override
  Widget build(BuildContext context) {
    final appLocale = AppLocalizations.of(context);
    return ListItem.open(
      leading: const Icon(Icons.cloud_sync),
      title: Text(appLocale.backupAndRecovery),
      subtitle: Text(appLocale.backupAndRecoveryDesc),
      delegate: OpenDelegate(
        title: appLocale.backupAndRecovery,
        widget: const BackupAndRecovery(),
      ),
    );
  }
}

class _HotkeyItem extends StatelessWidget {
  const _HotkeyItem();

  @override
  Widget build(BuildContext context) {
    final appLocale = AppLocalizations.of(context);
    return ListItem.open(
      leading: const Icon(Icons.keyboard),
      title: Text(appLocale.hotkeyManagement),
      subtitle: Text(appLocale.hotkeyManagementDesc),
      delegate: OpenDelegate(
        title: appLocale.hotkeyManagement,
        widget: const HotKeyView(),
      ),
    );
  }
}

class _LoopbackItem extends StatelessWidget {
  const _LoopbackItem();

  @override
  Widget build(BuildContext context) {
    final appLocale = AppLocalizations.of(context);
    return ListItem(
      leading: const Icon(Icons.lock),
      title: Text(appLocale.loopback),
      subtitle: Text(appLocale.loopbackDesc),
      onTap: () {
        windows?.runas(
          '"${join(dirname(Platform.resolvedExecutable), "EnableLoopback.exe")}"',
          "",
        );
      },
    );
  }
}

class _AccessItem extends StatelessWidget {
  const _AccessItem();

  @override
  Widget build(BuildContext context) {
    final appLocale = AppLocalizations.of(context);
    return ListItem.open(
      leading: const Icon(Icons.view_list),
      title: Text(appLocale.accessControl),
      subtitle: Text(appLocale.accessControlDesc),
      delegate: OpenDelegate(
        title: appLocale.appAccessControl,
        widget: const AccessView(),
      ),
    );
  }
}

class _ConfigItem extends StatelessWidget {
  const _ConfigItem();

  @override
  Widget build(BuildContext context) {
    final appLocale = AppLocalizations.of(context);
    return ListItem.open(
      leading: const Icon(Icons.edit),
      title: Text(appLocale.basicConfig),
      subtitle: Text(appLocale.basicConfigDesc),
      delegate: OpenDelegate(
        title: appLocale.override,
        widget: const ConfigView(),
      ),
    );
  }
}

class _SettingItem extends StatelessWidget {
  const _SettingItem();

  @override
  Widget build(BuildContext context) {
    final appLocale = AppLocalizations.of(context);
    return ListItem.open(
      leading: const Icon(Icons.settings),
      title: Text(appLocale.application),
      subtitle: Text(appLocale.applicationDesc),
      delegate: OpenDelegate(
        title: appLocale.application,
        widget: const ApplicationSettingView(),
      ),
    );
  }
}

class _RuntimeConfigItem extends StatelessWidget {
  const _RuntimeConfigItem();

  @override
  Widget build(BuildContext context) {
    final appLocale = AppLocalizations.of(context);
    return ListItem(
      leading: const Icon(Icons.code),
      title: Text(appLocale.runtimeConfig),
      onTap: () {
        final config = globalState.lastRuntimeConfig;
        if (config == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(appLocale.runtimeConfigNotAvailable)),
          );
          return;
        }

        final buffer = StringBuffer();
        yamlDump(buffer, config, 0);

        showExtend(
          context,
          builder: (_, type) => _RuntimeConfigSheet(
            type: type,
            text: buffer.toString(),
          ),
        );
      },
    );
  }
}

class _RuntimeConfigSheet extends ConsumerStatefulWidget {
  const _RuntimeConfigSheet({required this.type, required this.text});
  final SheetType type;
  final String text;

  @override
  ConsumerState<_RuntimeConfigSheet> createState() =>
      _RuntimeConfigSheetState();
}

class _RuntimeConfigSheetState extends ConsumerState<_RuntimeConfigSheet> {
  late final CodeLineEditingController _controller;
  late final CodeFindController _findController;

  @override
  void initState() {
    super.initState();
    _controller = CodeLineEditingController.fromText(widget.text);
    _findController = CodeFindController(_controller);
  }

  @override
  void dispose() {
    _findController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMobileView = ref.watch(isMobileViewProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AdaptiveSheetScaffold(
      type: widget.type,
      title: AppLocalizations.of(context).runtimeConfig,
      actions: [
        IconButton(
          onPressed: _findController.findMode,
          icon: const Icon(Icons.search),
        ),
      ],
      body: CodeEditor(
        readOnly: true,
        controller: _controller,
        findController: _findController,
        findBuilder: (context, controller, readOnly) => FindPanel(
          controller: controller,
          readOnly: readOnly,
          isMobileView: isMobileView,
        ),
        padding: const EdgeInsets.only(right: 16),
        scrollbarBuilder: (context, child, details) => CommonScrollBar(
          controller: details.controller,
          child: child,
        ),
        toolbarController: ContextMenuControllerImpl(editable: false),
        indicatorBuilder: (
          context,
          editingController,
          chunkController,
          notifier,
        ) =>
            Row(
          children: [
            DefaultCodeLineNumber(
              controller: editingController,
              notifier: notifier,
            ),
            const SizedBox(width: 16),
          ],
        ),
        style: CodeEditorStyle(
          fontSize: context.textTheme.bodyLarge?.fontSize?.ap,
          fontFamily: FontFamily.jetBrainsMono.value,
          codeTheme: CodeHighlightTheme(
            languages: {'yaml': CodeHighlightThemeMode(mode: langYaml)},
            theme: isDark ? atomOneDarkTheme : atomOneLightTheme,
          ),
        ),
      ),
    );
  }
}

class _DisclaimerItem extends StatelessWidget {
  const _DisclaimerItem();

  @override
  Widget build(BuildContext context) {
    final appLocale = AppLocalizations.of(context);
    return ListItem(
      leading: const Icon(Icons.gavel),
      title: Text(appLocale.disclaimer),
      onTap: () async {
        final isDisclaimerAccepted =
            await globalState.appController.showDisclaimer();
        if (!isDisclaimerAccepted) {
          globalState.appController.handleExit();
        }
      },
    );
  }
}

class _InfoItem extends StatelessWidget {
  const _InfoItem();

  @override
  Widget build(BuildContext context) {
    final appLocale = AppLocalizations.of(context);
    return ListItem.open(
      leading: const Icon(Icons.info),
      title: Text(appLocale.about),
      delegate: OpenDelegate(
        title: appLocale.about,
        widget: const AboutView(),
      ),
    );
  }
}

class _DeveloperItem extends StatelessWidget {
  const _DeveloperItem();

  @override
  Widget build(BuildContext context) {
    final appLocale = AppLocalizations.of(context);
    return ListItem.open(
      leading: const Icon(Icons.developer_board),
      title: Text(appLocale.developerMode),
      delegate: OpenDelegate(
        title: appLocale.developerMode,
        widget: const DeveloperView(),
      ),
    );
  }
}

enum _CoreState { running, restarting, stopped }

class _CoreStatusItem extends StatefulWidget {
  const _CoreStatusItem();

  @override
  State<_CoreStatusItem> createState() => _CoreStatusItemState();
}

class _CoreStatusItemState extends State<_CoreStatusItem> {
  _CoreState _state = _CoreState.stopped;

  @override
  void initState() {
    super.initState();
    _checkCoreStatus();
  }

  Future<void> _checkCoreStatus() async {
    try {
      final alive = await clashCore.isInit;
      if (mounted) {
        setState(() => _state = alive ? _CoreState.running : _CoreState.stopped);
      }
    } catch (_) {
      if (mounted) setState(() => _state = _CoreState.stopped);
    }
  }

  Color get _statusColor => switch (_state) {
    _CoreState.running => Colors.green,
    _CoreState.restarting => Colors.orange,
    _CoreState.stopped => Colors.red,
  };

  String _statusText(AppLocalizations l) => switch (_state) {
    _CoreState.running => l.coreStatusRunning,
    _CoreState.restarting => l.coreStatusRestarting,
    _CoreState.stopped => l.coreStatusStopped,
  };

  Future<void> _restart() async {
    if (_state == _CoreState.restarting) return;
    setState(() => _state = _CoreState.restarting);
    try {
      await globalState.appController.restartCore();
      if (mounted) setState(() => _state = _CoreState.running);
    } catch (_) {
      if (mounted) setState(() => _state = _CoreState.stopped);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appLocale = AppLocalizations.of(context);
    return ListItem(
      leading: Icon(Icons.memory, color: _statusColor),
      title: Text(appLocale.restartCore),
      subtitle: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _statusColor,
            ),
          ),
          const SizedBox(width: 6),
          Text(_statusText(appLocale)),
        ],
      ),
      onTap: _restart,
    );
  }
}
