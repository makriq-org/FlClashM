import '../../clash/lib.dart';
import 'backend_client.dart';

export 'backend_client.dart';
export 'backend_edits.dart';

final backendClient = BackendClient(
  transport: (request) {
    final bridge = clashLib;
    if (bridge == null) {
      throw UnsupportedError('Android backend host is required');
    }
    return bridge.invokeBackend(request);
  },
  events: clashLib?.backendEvents ?? const Stream.empty(),
);
