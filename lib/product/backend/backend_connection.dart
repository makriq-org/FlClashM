/// Readiness of the UI's IPC connection. No runtime or VPN intent lives here.
class BackendConnection {
  BackendConnection({required this.connect});

  final Future<bool> Function() connect;
  Future<bool>? _pending;
  bool _ready = false;
  int _epoch = 0;

  bool get connecting => _pending != null;

  Future<bool> ensure() {
    if (_ready) return Future.value(true);
    final pending = _pending;
    if (pending != null) return pending;
    final epoch = _epoch;
    final attempt = Future<bool>.sync(connect).then((success) {
      if (epoch != _epoch) return false;
      _ready = success;
      return success;
    });
    late final Future<bool> settled;
    settled = attempt.whenComplete(() {
      if (identical(_pending, settled)) _pending = null;
    });
    _pending = settled;
    return settled;
  }

  void invalidate() {
    _epoch++;
    _ready = false;
    _pending = null;
  }
}
