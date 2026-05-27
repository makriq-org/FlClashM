import 'dart:io';

import 'package:flclashx/clash/core.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/core_version.dart';
import 'package:flclashx/common/yaml_dump.dart';
import 'package:flclashx/common/yaml_highlight.dart';
import 'package:flclashx/l10n/l10n.dart';
import 'package:flclashx/models/models.dart';
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
        if (system.isDesktop) const _CoreUpdateItem(),
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
          builder: (_, type) => AdaptiveSheetScaffold(
            type: type,
            title: appLocale.runtimeConfig,
            body: _RuntimeConfigBody(text: buffer.toString()),
          ),
        );
      },
    );
  }
}

class _RuntimeConfigBody extends StatefulWidget {
  const _RuntimeConfigBody({required this.text});
  final String text;

  @override
  State<_RuntimeConfigBody> createState() => _RuntimeConfigBodyState();
}

class _RuntimeConfigBodyState extends State<_RuntimeConfigBody> {
  late final YamlHighlightController _yamlController;
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _yamlController = YamlHighlightController(text: widget.text);
  }

  @override
  void dispose() {
    _yamlController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearch(String query) {
    setState(() => _query = query);
    if (query.isEmpty) {
      _yamlController.setSearch('', [], -1);
      return;
    }
    final text = widget.text.toLowerCase();
    final q = query.toLowerCase();
    final matches = <int>[];
    var start = 0;
    while (true) {
      final idx = text.indexOf(q, start);
      if (idx == -1) break;
      matches.add(idx);
      start = idx + 1;
    }
    _yamlController.setSearch(query, matches, matches.isNotEmpty ? 0 : -1);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: AppLocalizations.of(context).search,
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        _onSearch('');
                      },
                    )
                  : null,
            ),
            onChanged: _onSearch,
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _yamlController,
              readOnly: true,
              maxLines: null,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.5,
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
      ],
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

class _CoreUpdateItem extends StatefulWidget {
  const _CoreUpdateItem();

  @override
  State<_CoreUpdateItem> createState() => _CoreUpdateItemState();
}

class _CoreUpdateItemState extends State<_CoreUpdateItem> {
  String _status = '';
  Map<String, dynamic>? _release;
  bool _busy = false;
  double _progress = 0;
  bool _downloading = false;

  String get _coreAssetName {
    final arch = Platform.version.contains('arm64') ||
            Platform.version.contains('aarch64')
        ? 'arm64'
        : 'amd64';
    final platform = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
            ? 'macos'
            : 'linux';
    final ext = Platform.isWindows ? '.exe' : '';
    return 'FlClashCore-$platform-$arch$ext';
  }

  bool _initialCheckDone = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialCheckDone) {
      _initialCheckDone = true;
      _check();
    }
  }

  Future<void> _check() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = AppLocalizations.of(context).coreUpdateChecking;
    });
    try {
      final coreVersion = await clashCore.getCoreVersion();
      final currentVersion = coreVersion.isNotEmpty ? coreVersion : kCoreVersionFromSource;
      _release = await request.checkForCoreUpdate(currentVersion);
      if (mounted) {
        setState(() {
          _busy = false;
          _status = _release != null
              ? (_release!['tag_name'] as String).replaceFirst('core-', '')
              : currentVersion;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '$e';
        });
      }
    }
  }

  Future<void> _download() async {
    if (_busy || _release == null) return;
    final assets = _release!['assets'] as List<dynamic>? ?? [];
    final name = _coreAssetName;
    final asset = assets.cast<Map<String, dynamic>>().where(
      (a) => (a['name'] as String?) == name,
    ).firstOrNull;
    if (asset == null) {
      setState(() => _status = '${AppLocalizations.of(context).coreUpdateFailed}: $name not found');
      return;
    }
    final url = asset['browser_download_url'] as String;
    setState(() {
      _busy = true;
      _downloading = true;
      _progress = 0;
      _status = AppLocalizations.of(context).coreUpdateDownloading;
    });
    final error = await request.downloadCoreUpdate(
      url,
      appPath.corePendingPath,
      onProgress: (received, total) {
        if (!mounted || total <= 0) return;
        setState(() => _progress = received / total);
      },
    );
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _busy = false;
        _downloading = false;
        _status = '${AppLocalizations.of(context).coreUpdateFailed}: $error';
      });
      return;
    }
    setState(() {
      _downloading = false;
      _busy = false;
    });
    if (!mounted) return;
    _showRestartDialog();
  }

  void _showRestartDialog() {
    final appLocale = AppLocalizations.of(context);
    globalState.showCommonDialog(
      dismissible: false,
      child: CommonDialog(
        title: appLocale.coreUpdateSuccess,
        actions: [
          TextButton(
            onPressed: () => globalState.appController.handleRestart(),
            child: Text(appLocale.restart),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appLocale = AppLocalizations.of(context);
    final hasUpdate = _release != null && !_busy;
    final color = hasUpdate
        ? Theme.of(context).colorScheme.primary
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListItem(
          leading: Icon(
            hasUpdate ? Icons.system_update : Icons.update,
            color: color,
          ),
          title: Text(
            hasUpdate
                ? appLocale.coreUpdateAvailable
                : appLocale.coreUpdate,
            style: hasUpdate ? TextStyle(color: color, fontWeight: FontWeight.bold) : null,
          ),
          subtitle: _status.isNotEmpty ? Text(_status) : null,
          onTap: _release != null ? _download : _check,
        ),
        if (_downloading)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(value: _progress > 0 ? _progress : null),
          ),
      ],
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
