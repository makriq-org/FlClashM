import 'dart:async';
import 'dart:convert';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/common.dart';
import 'package:flclashx/models/core.dart';
import 'package:flclashx/models/profile.dart';
import 'package:flclashx/pages/editor.dart';
import 'package:flclashx/product/backend/backend.dart';
import 'package:flclashx/product/backend/resource_client.dart';
import 'package:flclashx/providers/action.dart';
import 'package:flclashx/providers/app.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/ui/icons/icons.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

class ExternalProvidersSliver extends ConsumerStatefulWidget {
  final List<ExternalProvider> providers;

  const ExternalProvidersSliver({super.key, required this.providers});

  @override
  ConsumerState<ExternalProvidersSliver> createState() =>
      _ExternalProvidersSliverState();
}

class _ExternalProvidersSliverState
    extends ConsumerState<ExternalProvidersSliver> {
  bool _isUpdating = false;

  Future<void> _updateProviders() async {
    final appLocalizations = context.appLocalizations;
    final proxiesAction = ref.read(proxiesActionProvider.notifier);
    final List<UpdatingMessage> messages = [];
    setState(() => _isUpdating = true);
    try {
      await Future.wait(
        widget.providers.map((provider) async {
          try {
            final message = await proxiesAction.updateProvider(
              provider,
              showLoading: true,
            );
            if (message.isNotEmpty) {
              messages.add(
                UpdatingMessage(label: provider.name, message: message),
              );
            }
          } catch (error) {
            messages.add(
              UpdatingMessage(
                label: provider.name,
                message: userFacingErrorMessage(error, appLocalizations),
              ),
            );
          }
        }),
      );
    } finally {
      if (mounted) {
        setState(() => _isUpdating = false);
      }
    }
    proxiesAction.updateGroupsDebounce();
    dialogs.showFailures(messages);
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final providers = widget.providers;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: ListHeader(
            title: appLocalizations.providers,
            actions: [
              IconButtonData(
                glyph: AppGlyphs.sync,
                tooltip: appLocalizations.update,
                isLoading: _isUpdating,
                onPressed: _updateProviders,
              ),
            ],
          ),
        ),
        SliverList.builder(
          itemCount: providers.length,
          itemBuilder: (_, index) {
            final provider = providers[index];
            final position = ItemPosition.get(index, providers.length);
            return ItemPositionProvider(
              position: position,
              child: ProviderItem(
                key: ValueKey(provider.name),
                provider: provider,
              ),
            );
          },
        ),
      ],
    );
  }
}

class ProviderItem extends ConsumerStatefulWidget {
  final ExternalProvider provider;

  const ProviderItem({super.key, required this.provider});

  @override
  ConsumerState<ProviderItem> createState() => _ProviderItemState();
}

class _ProviderItemState extends ConsumerState<ProviderItem> {
  final _resources = BackendResourceClient(backendClient);
  ProviderInspection? _inspection;
  Object? _inspectionError;
  int _inspectionRequest = 0;
  bool _isAppRuleSet = false;

  ExternalProvider get provider => widget.provider;

  bool get _isSyncable => provider.vehicleType == 'HTTP' || _isAppRuleSet;

  // The opaque path is only a capability flag. Inline/Compatible providers
  // have no cached resource, so inspecting them would only produce errors.
  bool get _hasResource =>
      provider.path?.isNotEmpty == true &&
      provider.vehicleType != 'Inline' &&
      provider.vehicleType != 'Compatible';

  @override
  void initState() {
    super.initState();
    unawaited(_inspectProvider());
  }

  @override
  void didUpdateWidget(covariant ProviderItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider.name != provider.name ||
        oldWidget.provider.type != provider.type ||
        oldWidget.provider.path != provider.path ||
        oldWidget.provider.vehicleType != provider.vehicleType ||
        oldWidget.provider.updateAt != provider.updateAt) {
      unawaited(_inspectProvider());
    }
  }

  Future<void> _inspectProvider() async {
    if (!mounted) return;
    final request = ++_inspectionRequest;
    if (!_hasResource) {
      setState(() {
        _inspection = null;
        _inspectionError = null;
        _isAppRuleSet = false;
      });
      return;
    }
    final current = provider;
    final clashProvidersAction = ref.read(
      clashProvidersActionProvider.notifier,
    );
    try {
      final inspection = await _resources.inspectProvider(
        name: current.name,
        type: current.type,
      );
      final isAppRuleSet =
          await clashProvidersAction.remoteProviderOf(current) != null;
      if (!mounted || request != _inspectionRequest) return;
      setState(() {
        _inspection = inspection;
        _inspectionError = null;
        _isAppRuleSet = isAppRuleSet;
      });
    } catch (error) {
      if (!mounted || request != _inspectionRequest) return;
      setState(() {
        _inspection = null;
        _inspectionError = error;
      });
    }
  }

  Future<void> _handleUpdateProvider() async {
    if (!_isSyncable) return;
    final proxiesAction = ref.read(proxiesActionProvider.notifier);
    await globalState.safeRun(() async {
      final message = await proxiesAction.updateProvider(
        provider,
        showLoading: true,
      );
      if (message.isNotEmpty) throw MessageException(message);
    }, silence: false);
    proxiesAction.updateGroupsDebounce();
    await _inspectProvider();
  }

  Future<void> _handleSideLoadProvider() async {
    final proxiesAction = ref.read(proxiesActionProvider.notifier);
    await globalState.safeRun<void>(() async {
      final platformFile = await picker.pickerFile();
      if (platformFile == null) return;
      await _sideLoadProvider(ref, provider, await platformFile.readBytes());
    });
    proxiesAction.updateGroupsDebounce();
    await _inspectProvider();
  }

  void _handleEditProvider(BuildContext context) {
    unawaited(
      BaseNavigator.push<void>(
        context,
        _EditProviderView(provider: provider),
      ).then((_) {
        if (mounted) unawaited(_inspectProvider());
      }),
    );
  }

  void _handlePreviewProvider(BuildContext context) {
    final current = provider;
    unawaited(
      BaseNavigator.push<void>(
        context,
        EditorPage(
          title: current.name,
          load: () => _resources.readProviderText(
            name: current.name,
            type: current.type,
          ),
          schema: EditorSchema.provider,
        ),
      ),
    );
  }

  void _handleShowSubscriptionInfo() {
    unawaited(
      dialogs.showCommonDialog<void>(
        child: Builder(
          builder: (context) {
            return CommonDialog(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              title: context.appLocalizations.subscriptionInfo,
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  child: Text(context.appLocalizations.confirm),
                ),
              ],
              child: SubscriptionInfoDetailView(
                subscriptionInfo: provider.subscriptionInfo!,
              ),
            );
          },
        ),
      ),
    );
  }

  List<CommonPopupMenuItem> _menuItems(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final subscriptionInfo = provider.subscriptionInfo;
    return [
      if (_inspection?.format == ResourceFormat.text &&
          _inspection?.editable == true)
        CommonPopupMenuItem(
          glyph: AppGlyphs.edit,
          label: appLocalizations.edit,
          onPressed: () {
            _handleEditProvider(context);
          },
        ),
      if (_inspection?.format == ResourceFormat.mrs)
        CommonPopupMenuItem(
          glyph: AppGlyphs.eye,
          label: appLocalizations.preview,
          onPressed: () {
            _handlePreviewProvider(context);
          },
        ),
      CommonPopupMenuItem(
        glyph: AppGlyphs.upload,
        label: appLocalizations.upload,
        onPressed: () {
          _handleSideLoadProvider();
        },
      ),
      if (_isSyncable)
        CommonPopupMenuItem(
          glyph: AppGlyphs.sync,
          label: appLocalizations.sync,
          onPressed: () {
            _handleUpdateProvider();
          },
        ),
      if (subscriptionInfo != null && subscriptionInfo.total > 0)
        CommonPopupMenuItem(
          glyph: AppGlyphs.dataUsage,
          label: appLocalizations.subscriptionInfo,
          onPressed: _handleShowSubscriptionInfo,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isUpdating = ref.watch(isUpdatingProvider(provider.updatingKey));
    final previewable =
        _inspection != null && _inspection!.format != ResourceFormat.binary;
    final inspectionError = _inspectionError;
    return ContextMenuRegion(
      menuItems: isUpdating ? null : _menuItems(context),
      child: _ExternalProviderItem(
        provider: provider,
        isUpdating: isUpdating,
        error: inspectionError == null
            ? null
            : userFacingErrorMessage(inspectionError, context.appLocalizations),
        onPressed: isUpdating
            ? null
            : inspectionError != null
            ? () => unawaited(_inspectProvider())
            : !previewable
            ? null
            : () => _handlePreviewProvider(context),
      ),
    );
  }
}

class _ExternalProviderItem extends StatelessWidget {
  final ExternalProvider provider;
  final bool isUpdating;
  final VoidCallback? onPressed;
  final String? error;

  const _ExternalProviderItem({
    required this.provider,
    required this.isUpdating,
    this.onPressed,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final count = provider.count;
    final updateAt = provider.updateAt;
    return DecorationListItem(
      onPressed: onPressed,
      title: ChipTitle(
        title: provider.name,
        expire: provider.subscriptionInfo?.expireDate,
      ),
      subtitle: Text(
        error ??
            switch (provider.type) {
              'Proxy' => appLocalizations.proxiesCount(count, count.compact),
              _ => appLocalizations.rulesCount(count, count.compact),
            },
      ),
      trailing: AnimatedSwitcher(
        duration: context.motionDuration(commonDuration),
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.centerRight,
          children: [...previous, ?current],
        ),
        child: isUpdating
            ? const CommonCircleLoading(key: ValueKey('loading'), size: 24)
            : LastUpdateTimeText(
                key: const ValueKey('time'),
                lastUpdateDate: updateAt.microsecondsSinceEpoch > 0
                    ? updateAt
                    : null,
                compact: true,
                style: context.listCaptionStyle,
              ),
      ),
    );
  }
}

String _decodeProviderFile(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw MessageException(currentAppLocalizations.nonTextProviderFile);
  }
}

Future<void> _sideLoadProvider(
  WidgetRef ref,
  ExternalProvider provider,
  List<int> bytes,
) async {
  final data = _decodeProviderFile(bytes);
  final message = await ref
      .read(proxiesActionProvider.notifier)
      .sideLoadExternalProvider(provider, data, showLoading: true);
  if (message.isNotEmpty) throw MessageException(message);
}

class _EditProviderView extends ConsumerStatefulWidget {
  final ExternalProvider provider;

  const _EditProviderView({required this.provider});

  @override
  ConsumerState<_EditProviderView> createState() => _EditProviderViewState();
}

class _EditProviderViewState extends ConsumerState<_EditProviderView> {
  String? _raw;

  Future<String> _load() async => _raw = await BackendResourceClient(
    backendClient,
  ).readProviderText(name: widget.provider.name, type: widget.provider.type);

  Future<void> _handleSave(BuildContext context, String content) async {
    final proxiesAction = ref.read(proxiesActionProvider.notifier);
    final saved = await globalState.safeRun<bool>(() async {
      await _sideLoadProvider(ref, widget.provider, utf8.encode(content));
      return true;
    }, silence: false);
    if (saved != true) {
      return;
    }
    proxiesAction.updateGroupsDebounce();
    if (context.mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<bool> _handlePop(BuildContext context, String content) async {
    final raw = _raw;
    if (raw == null || content == raw) {
      return true;
    }
    final res = await dialogs.showMessage(
      title: widget.provider.name,
      message: TextSpan(text: context.appLocalizations.saveChanges),
    );
    if (res == null) {
      return false;
    }
    if (!res || !context.mounted) {
      return true;
    }
    unawaited(_handleSave(context, content));
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return EditorPage(
      title: widget.provider.name,
      load: _load,
      schema: EditorSchema.provider,
      onSave: (context, _, content) => _handleSave(context, content),
      onPop: (context, _, content) => _handlePop(context, content),
    );
  }
}
