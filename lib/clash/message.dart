import 'dart:async';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flutter/foundation.dart';

class ClashMessage {

  // ignore: unused_field
  late final StreamSubscription _subscription;

  ClashMessage._() {
    _subscription = controller.stream.listen(
      (message) {
        if (message.isEmpty) {
          return;
        }
        try {
          final m = AppMessage.fromJson(message);
          // Parse m.data once (not once per listener) before fanning out.
          switch (m.type) {
            case AppMessageType.log:
              final log = Log.fromJson(m.data);
              for (final listener in _listeners) {
                listener.onLog(log);
              }
              break;
            case AppMessageType.delay:
              final delay = Delay.fromJson(m.data);
              for (final listener in _listeners) {
                listener.onDelay(delay);
              }
              break;
            case AppMessageType.request:
              final connection = Connection.fromJson(m.data);
              for (final listener in _listeners) {
                listener.onRequest(connection);
              }
              break;
            case AppMessageType.loaded:
              for (final listener in _listeners) {
                listener.onLoaded(m.data);
              }
              break;
          }
        } catch (e) {
          // A single malformed event must not throw an uncaught zone error.
          commonPrint.log('clashMessage event parse error: $e');
        }
      },
    );
  }
  final controller = StreamController<Map<String, Object?>>();

  static final ClashMessage instance = ClashMessage._();

  final ObserverList<AppMessageListener> _listeners =
      ObserverList<AppMessageListener>();

  bool get hasListeners => _listeners.isNotEmpty;

  void addListener(AppMessageListener listener) {
    _listeners.add(listener);
  }

  void removeListener(AppMessageListener listener) {
    _listeners.remove(listener);
  }
}

final clashMessage = ClashMessage.instance;
