import 'dart:async';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

import '../backend/backend.dart';

/// The backend owns the temporary receiver. Leaving this page closes it.
class LinkSessionPage extends StatefulWidget {
  const LinkSessionPage({super.key});

  @override
  State<LinkSessionPage> createState() => _LinkSessionPageState();
}

class _LinkSessionPageState extends State<LinkSessionPage>
    with WidgetsBindingObserver {
  String? _url;
  String? _sessionId;
  Object? _error;
  Timer? _timer;
  bool _reading = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final result = await backendClient.request('linkSession.start', {});
      final sessionId = (result as Map)['sessionId'] as String;
      if (!mounted || _closed) {
        await backendClient.request('linkSession.stop', {
          'sessionId': sessionId,
        });
        return;
      }
      _sessionId = sessionId;
      setState(() => _url = result['url'] as String);
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _read());
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _read() async {
    if (_reading || _closed) return;
    _reading = true;
    try {
      final result = await backendClient.request('linkSession.get', {
        'sessionId': _sessionId,
      }) as Map;
      if (!mounted || _closed) return;
      final link = result['link'] as String?;
      if (link != null || result['url'] == '') {
        _close();
        if (ModalRoute.isCurrentOf(context) == true) {
          Navigator.of(context).pop(link);
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
      _close();
    } finally {
      _reading = false;
    }
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    if (_sessionId != null) {
      unawaited(
        backendClient
            .request('linkSession.stop', {'sessionId': _sessionId})
            .catchError((_) => null),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _close();
      if (mounted && ModalRoute.isCurrentOf(context) == true) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CommonScaffold(
    title: context.appLocalizations.sendFromPhone,
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: _error != null
            ? Text(context.appLocalizations.sendFromPhoneNoNetwork)
            : _url == null
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  QrCodeView(data: _url!),
                  const SizedBox(height: 16),
                  Text(context.appLocalizations.sendFromPhoneTip),
                  const SizedBox(height: 16),
                  SelectableText(_url!),
                ],
              ),
      ),
    ),
  );
}
