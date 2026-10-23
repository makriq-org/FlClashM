import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/pages/editor.dart';
import 'package:flclashx/pages/editor_window.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/product/backend/backend.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';

class EditProfileView extends StatefulWidget {

  const EditProfileView({
    super.key,
    required this.context,
    required this.profile,
  });
  final Profile profile;
  final BuildContext context;

  @override
  State<EditProfileView> createState() => _EditProfileViewState();
}

class _EditProfileViewState extends State<EditProfileView> {
  late TextEditingController labelController;
  late TextEditingController urlController;
  late TextEditingController autoUpdateDurationController;
  late bool autoUpdate;
  String? rawText;
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final fileInfoNotifier = ValueNotifier<FileInfo?>(null);
  Uint8List? fileData;

  Profile get profile => widget.profile;

  Future<void>? _loading;
  int _revision = 0;

  // A failed load is retried by the next action instead of being cached.
  Future<void> _loaded() async {
    final loading = _loading ??= _load();
    try {
      await loading;
    } catch (_) {
      if (identical(_loading, loading)) _loading = null;
      rethrow;
    }
  }

  Future<void> _load() async {
    final record = await backendClient.profile(profile.id);
    if (!mounted) return;
    _revision = (record['revision'] as num).toInt();
    rawText = record['source'] as String;
    fileInfoNotifier.value = FileInfo(
      size: utf8.encode(rawText!).length,
      lastModified:
          profile.lastUpdateDate ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  @override
  void dispose() {
    labelController.dispose();
    urlController.dispose();
    autoUpdateDurationController.dispose();
    fileInfoNotifier.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    labelController = TextEditingController(text: widget.profile.label);
    urlController = TextEditingController(text: widget.profile.url);
    autoUpdate = widget.profile.autoUpdate;
    autoUpdateDurationController = TextEditingController(
      text: widget.profile.autoUpdateDuration.inMinutes.toString(),
    );
    unawaited(
      _loaded().catchError((error) {
        commonPrint.log('Profile load failed: $error');
      }),
    );
  }

  Future<void> _handleConfirm() async {
    if (!_formKey.currentState!.validate()) return;
    var draft = profile.copyWith(
          url: urlController.text,
          label: labelController.text,
          autoUpdate: autoUpdate,
          autoUpdateDuration: Duration(
            minutes: int.parse(
              autoUpdateDurationController.text,
            ),
          ),
        );
    if (fileData != null && draft.type == ProfileType.url && autoUpdate) {
      final disable = await globalState.showMessage(
        title: appLocalizations.tip,
        message: TextSpan(
          text: appLocalizations.profileHasUpdate,
        ),
      );
      if (disable == true) draft = draft.copyWith(autoUpdate: false);
    }
    final scaffold = globalState.homeScaffoldKey.currentState;
    Future<bool?> save() =>
        globalState.safeRun(() => _save(draft), silence: false);
    final saved = scaffold != null && scaffold.mounted
        ? await scaffold.loadingRun(save)
        : await save();
    // On failure the error was shown and the sheet stays open for a retry.
    if (saved == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<bool> _save(Profile draft) async {
    await _loaded();
    try {
      final data = fileData;
      if (data != null) {
        final receipt = await backendClient.saveSource(
          draft.toBackendMetadata(),
          data,
          expectedRevision: _revision,
        );
        _revision = (receipt['revision'] as num).toInt();
        fileData = null;
      } else {
        final receipt = await backendClient.command('profile.put', {
          'metadata': draft.toBackendMetadata(),
          'expectedRevision': _revision,
        });
        _revision = (receipt['revision'] as num).toInt();
        if (widget.profile.url != draft.url) {
          await backendClient.command('subscription.refresh', {
            'profileId': draft.id,
          });
        }
      }
      return true;
    } catch (error) {
      _rememberCommittedRevision(error);
      rethrow;
    }
  }

  void _rememberCommittedRevision(Object error) {
    if (error is BackendCommittedException) {
      _revision = error.revisionFor(widget.profile.id) ?? _revision;
    }
  }

  void _setAutoUpdate(bool value) {
    if (autoUpdate == value) return;
    setState(() {
      autoUpdate = value;
    });
  }

  Future<void> _handleSaveEdit(BuildContext context, String data) async {
    final message = await globalState.safeRun<String>(
      () async {
        final message = await globalState.validateProfileConfigText(data);
        return message;
      },
      silence: false,
    );
    if (message?.isNotEmpty == true) {
      globalState.showMessage(
        title: appLocalizations.tip,
        message: TextSpan(text: message),
      );
      return;
    }
    if (context.mounted) {
      Navigator.of(context).pop(data);
    }
  }

  Future<void> _editProfileFile() async {
    try {
      await _loaded();
    } catch (error) {
      globalState.showNotifier(globalState.describeError(error));
      return;
    }
    if (!mounted) return;
    final title = widget.profile.label ?? widget.profile.id;

    // macOS lives in the tray popover — too cramped to edit a config. Open it in
    // a standalone native window (its own engine, see editor_window). Its Save
    // round-trips here to validate + persist via the core, then closes.
    if (Platform.isMacOS) {
      await EditorWindowBridge.open(
        title: title,
        content: rawText!,
        isDark: Theme.of(context).brightness == Brightness.dark,
        saveLabel: appLocalizations.save,
        // A URL profile with auto-update on would overwrite manual edits on its
        // next refresh — the window asks whether to disable auto-update, exactly
        // like _handleConfirm does for the in-app editor.
        promptAutoUpdate: widget.profile.type == ProfileType.url && autoUpdate,
        promptTitle: appLocalizations.tip,
        promptMessage: appLocalizations.profileHasUpdate,
        confirmLabel: appLocalizations.confirm,
        cancelLabel: appLocalizations.cancel,
        onSave: (content, disableAutoUpdate) async {
          try {
            final receipt = await backendClient.saveSource(
              widget.profile.toBackendMetadata(),
              Uint8List.fromList(utf8.encode(content)),
              expectedRevision: _revision,
            );
            _revision = (receipt['revision'] as num).toInt();
            if (disableAutoUpdate) {
              final updated = await backendClient.command('profile.put', {
                'metadata': {'id': widget.profile.id, 'autoUpdate': false},
                'expectedRevision': _revision,
              });
              _revision = (updated['revision'] as num).toInt();
            }
            if (mounted) {
              rawText = content;
              fileData = null;
              if (disableAutoUpdate) {
                setState(() => autoUpdate = false);
              }
              fileInfoNotifier.value = fileInfoNotifier.value?.copyWith(
                size: utf8.encode(content).length,
                lastModified: DateTime.now(),
              );
            }
            return null;
          } catch (e) {
            _rememberCommittedRevision(e);
            return e.toString();
          }
        },
      );
      return;
    }

    final editorPage = EditorPage(
      title: title,
      content: rawText!,
      onSave: (context, _, content) {
        _handleSaveEdit(context, content);
      },
      onPop: (context, _, content) async {
        if (content == rawText) {
          return true;
        }
        final res = await globalState.showMessage(
          title: title,
          message: TextSpan(
            text: appLocalizations.hasCacheChange,
          ),
        );
        if (res == true && context.mounted) {
          _handleSaveEdit(context, content);
        } else {
          return true;
        }
        return false;
      },
    );
    final data = await BaseNavigator.modal<String>(
      globalState.homeScaffoldKey.currentContext!,
      editorPage,
    );
    if (data == null) {
      return;
    }
    rawText = data;
    fileData = Uint8List.fromList(utf8.encode(data));
    fileInfoNotifier.value = fileInfoNotifier.value?.copyWith(
      size: fileData?.length ?? 0,
      lastModified: DateTime.now(),
    );
  }

  Future<void> _handleBack() async {
    final res = await globalState.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(text: appLocalizations.fileIsUpdate),
    );
    if (res == true) {
      _handleConfirm();
    } else {
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      ListItem(
        title: TextFormField(
          textInputAction: TextInputAction.next,
          controller: labelController,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: appLocalizations.name,
          ),
          validator: (value) {
            if (value == null || value.isEmpty) {
              return appLocalizations.profileNameNullValidationDesc;
            }
            return null;
          },
        ),
      ),
      if (widget.profile.type == ProfileType.url) ...[
        ListItem(
          title: TextFormField(
            textInputAction: TextInputAction.next,
            keyboardType: TextInputType.url,
            controller: urlController,
            maxLines: 5,
            minLines: 1,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: appLocalizations.url,
            ),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return appLocalizations.profileUrlNullValidationDesc;
              }
              if (!value.isUrl) {
                return appLocalizations.profileUrlInvalidValidationDesc;
              }
              return null;
            },
          ),
        ),
        ListItem.switchItem(
          title: Text(appLocalizations.autoUpdate),
          delegate: SwitchDelegate<bool>(
            value: autoUpdate,
            onChanged: _setAutoUpdate,
          ),
        ),
        if (autoUpdate)
          ListItem(
            title: TextFormField(
              textInputAction: TextInputAction.next,
              controller: autoUpdateDurationController,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: appLocalizations.autoUpdateInterval,
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return appLocalizations
                      .profileAutoUpdateIntervalNullValidationDesc;
                }
                try {
                  int.parse(value);
                } catch (_) {
                  return appLocalizations
                      .profileAutoUpdateIntervalInvalidValidationDesc;
                }
                return null;
              },
            ),
          ),
      ],
      ValueListenableBuilder<FileInfo?>(
        valueListenable: fileInfoNotifier,
        builder: (_, fileInfo, __) => FadeThroughBox(
            child: fileInfo == null
                ? Container()
                : ListItem(
                    title: Text(
                      appLocalizations.profile,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(
                          height: 4,
                        ),
                        Text(
                          fileInfo.desc,
                        ),
                        const SizedBox(
                          height: 8,
                        ),
                        Wrap(
                          runSpacing: 6,
                          spacing: 12,
                          children: [
                            CommonChip(
                              avatar: const Icon(Icons.edit),
                              label: appLocalizations.edit,
                              onPressed: _editProfileFile,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
          ),
      ),
    ];
    return CommonPopScope(
      onPop: () {
        if (fileData == null) {
          return true;
        }
        _handleBack();
        return false;
      },
      child: FloatLayout(
        floatingWidget: FloatWrapper(
          child: FloatingActionButton.extended(
            heroTag: null,
            onPressed: _handleConfirm,
            label: Text(appLocalizations.save),
            icon: const Icon(Icons.save),
          ),
        ),
        child: Form(
          key: _formKey,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: 16,
            ),
            child: ListView.separated(
              padding: kMaterialListPadding.copyWith(
                bottom: 72,
              ),
              itemBuilder: (_, index) => items[index],
              separatorBuilder: (_, __) => const SizedBox(
                  height: 24,
                ),
              itemCount: items.length,
            ),
          ),
        ),
      ),
    );
  }
}
