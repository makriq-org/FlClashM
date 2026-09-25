import 'dart:async';
import 'dart:io';

import 'package:flclashx/common/proxy.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/config.dart';
import 'package:flclashx/providers/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ProxyManager extends ConsumerStatefulWidget {
  const ProxyManager({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState createState() => _ProxyManagerState();
}

class _ProxyManagerState extends ConsumerState<ProxyManager> {
  Future<void> _pending = Future<void>.value();
  bool _started = false;

  void _disableFailedWindowsProxy() {
    if (!Platform.isWindows || !mounted) return;
    ref.read(networkSettingProvider.notifier).updateState(
      (settings) => settings.copyWith(systemProxy: false),
    );
  }

  Future<void> _updateProxy(ProxyState state) async {
    try {
      if (state.isStart && state.systemProxy) {
        // The Windows plugin journals the user's existing settings and starts a
        // same-user watchdog before changing WinINet. A failed start is visible.
        _started = await proxy?.startProxy(state.port, state.bassDomain) == true;
        if (!_started) {
          debugPrint('Could not enable the system proxy');
          _disableFailedWindowsProxy();
        }
      } else if (_started || Platform.isWindows) {
        // On Windows this also recovers an orphaned journal after a crash. When
        // there is no owner it is a strict no-op, including on first launch.
        final stopped = await proxy?.stopProxy() == true;
        if (!stopped) debugPrint('Could not restore the system proxy');
        _started = !stopped;
      }
    } catch (error) {
      debugPrint('System proxy operation failed: $error');
      if (state.isStart && state.systemProxy) _disableFailedWindowsProxy();
    }
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual(
      proxyStateProvider,
      (prev, next) {
        if (prev == next) return;
        // Native proxy mutations must complete in order. A rapid toggle must
        // not let a late StartProxy overwrite the following StopProxy.
        _pending = _pending.then((_) => _updateProxy(next));
      },
      fireImmediately: true,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
