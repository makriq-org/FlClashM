import 'package:flclashx/common/common.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/ui/list.dart';
import 'package:material_ui/material_ui.dart';

import '../backend/backend.dart';

/// The host-wide privacy preference is separate from per-profile headers.
class SendDeviceHeadersToggle extends StatefulWidget {
  const SendDeviceHeadersToggle({super.key, this.client});

  final BackendClient? client;

  @override
  State<SendDeviceHeadersToggle> createState() =>
      _SendDeviceHeadersToggleState();
}

class _SendDeviceHeadersToggleState extends State<SendDeviceHeadersToggle> {
  BackendClient get _client => widget.client ?? backendClient;
  bool _pending = false;

  Future<void> _save(bool value) async {
    setState(() => _pending = true);
    try {
      await _client.command('settings.patch', {
        'patch': {'sendDeviceHeaders': value},
      });
    } catch (error) {
      if (mounted && !isSilentBackendError(error)) {
        globalState.showNotifier(describeBackendError(error));
      }
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<Map<String, dynamic>>(
    stream: _client.changes,
    builder: (context, _) => ListItem.toggle(
      title: Text(context.appLocalizations.settingsSendDeviceDataTitle),
      subtitle: Text(context.appLocalizations.settingsSendDeviceDataSubtitle),
      value: _client.sourceSettings['sendDeviceHeaders'] as bool? ?? true,
      onChanged: _pending ? null : _save,
    ),
  );
}
