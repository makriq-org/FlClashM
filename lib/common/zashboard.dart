import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flclashx/common/print.dart';
import 'package:flclashx/state.dart';
import 'package:path/path.dart' as p;

// Public zashboard instance — kept only as a defensive fallback. With external-ui
// always pointed at a local dir (see patchRawConfig), the local panel is used.
const publicZashboardBase = 'https://board.zash.run.place';

// zashboard compiled bundle; the app downloads this into the external-ui dir on
// demand so the core serves it at /ui/ (same origin/http as the backend).
const zashboardDistUrl =
    'https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip';

/// Whether the local zashboard bundle is already extracted into external-ui.
Future<bool> isZashboardUiReady() async {
  final dir = globalState.effectiveExternalUi.value.trim();
  if (dir.isEmpty) return false;
  return File(p.join(dir, 'index.html')).exists();
}

/// Downloads + extracts the zashboard bundle into the external-ui dir if it isn't
/// there yet. The core serves that dir at /ui/ live, so files appear immediately.
/// Returns true when index.html is present afterwards.
Future<bool> ensureZashboardUi() async {
  final dir = globalState.effectiveExternalUi.value.trim();
  if (dir.isEmpty) return false;
  final index = File(p.join(dir, 'index.html'));
  if (await index.exists()) return true;
  try {
    final resp = await Dio().get<List<int>>(
      zashboardDistUrl,
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = resp.data;
    if (bytes == null || bytes.isEmpty) return false;
    final archive = ZipDecoder().decodeBytes(Uint8List.fromList(bytes));
    // dist.zip may nest everything under a top folder (e.g. dist/); find where
    // index.html sits and strip that prefix so files land at the dir root.
    var prefix = '';
    for (final f in archive) {
      if (f.isFile && p.basename(f.name) == 'index.html') {
        final d = p.dirname(f.name.replaceAll('\\', '/'));
        prefix = d == '.' ? '' : '$d/';
        break;
      }
    }
    for (final f in archive) {
      if (!f.isFile) continue;
      var name = f.name.replaceAll('\\', '/');
      if (prefix.isNotEmpty) {
        if (!name.startsWith(prefix)) continue;
        name = name.substring(prefix.length);
      }
      if (name.isEmpty) continue;
      final out = File(p.join(dir, name));
      await out.parent.create(recursive: true);
      await out.writeAsBytes(f.content as List<int>);
    }
    return await index.exists();
  } catch (e) {
    commonPrint.log('zashboard ui download failed: $e');
    return false;
  }
}

/// Builds the zashboard URL pointed at this client's external-controller:
/// .../#/setup?hostname=host&port=port&secret=secret&http=1 — host/port and
/// secret are taken from the active profile's external-controller config.
/// Returns null when external-controller is not set.
String? buildZashboardUrl() {
  final ec = globalState.effectiveExternalController.value.trim();
  if (ec.isEmpty) return null;
  final idx = ec.lastIndexOf(':');
  var host = idx > 0 ? ec.substring(0, idx).trim() : '';
  final port = idx >= 0 ? ec.substring(idx + 1).trim() : ec.trim();
  // 0.0.0.0/empty bind addresses aren't browser-reachable; assume same device.
  if (host.isEmpty || host == '0.0.0.0' || host == '::') {
    host = '127.0.0.1';
  }
  final secret = globalState.effectiveSecret.value.trim();
  // `http=1` forces zashboard's backend protocol to plain HTTP. Without it,
  // getBackendFromUrl falls back to the page's own protocol — and the public
  // instance is served over HTTPS, so it would probe https://host:port and the
  // auto-verify fails ("Backend configuration failed") even though the core
  // only speaks HTTP. The value must be non-empty (JS treats "" as falsy).
  final query =
      'hostname=$host&port=$port&secret=${Uri.encodeQueryComponent(secret)}&http=1';
  // Local panel: when the profile sets external-ui, the core downloads the
  // dashboard (external-ui-url) and serves it at the FIXED `/ui/` path on the
  // same host:port as the controller (mihomo hardcodes /ui/ — the external-ui
  // value is just the on-disk dir, not a URL segment). Same origin as the
  // backend, plain http, so it also loads inside WKWebView. When external-ui is
  // unset, fall back to the public instance.
  final hasLocalUi = globalState.effectiveExternalUi.value.trim().isNotEmpty;
  if (!hasLocalUi) {
    return '$publicZashboardBase/#/setup?$query';
  }
  return 'http://$host:$port/ui/#/setup?$query';
}
