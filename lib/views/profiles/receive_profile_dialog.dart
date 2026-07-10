import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/state.dart';
import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router;

/// Apply lifecycle shared between the TV UI and the phone (over `GET /status`).
enum _SyncStatus { waiting, applying, success, error }

class ReceiveProfileDialog extends StatefulWidget {
  const ReceiveProfileDialog({super.key});

  @override
  State<ReceiveProfileDialog> createState() => _ReceiveProfileDialogState();
}

class _ReceiveProfileDialogState extends State<ReceiveProfileDialog> {
  static const _syncPort = 8899;

  HttpServer? _server;
  String? _qrData;
  bool _isLoading = true;
  _SyncStatus _status = _SyncStatus.waiting;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    unawaited(_startServerAndGenerateQr());
  }

  Future<void> _startServerAndGenerateQr() async {
    try {
      final ip = await NetworkInfo().getWifiIP();
      if (ip == null || ip.isEmpty) {
        throw StateError('Could not get IP address');
      }

      final router = shelf_router.Router();

      // Landing page for phones without the app (e.g. iPhone): the native
      // camera opens this URL in the browser, where the user pastes the link.
      // Served from the TV itself so the form's POST is same-origin http→http
      // (a page hosted over https couldn't reach this LAN http endpoint).
      router.get(
        '/',
        (shelf.Request request) => shelf.Response.ok(
          _pageHtml,
          headers: {'content-type': 'text/html; charset=utf-8'},
        ),
      );

      // Phones poll this to watch the real apply result on the TV.
      router.get(
        '/status',
        (shelf.Request request) => shelf.Response.ok(
          jsonEncode({'status': _status.name, 'message': _statusMessage}),
          headers: {'content-type': 'application/json'},
        ),
      );

      router.post('/add-profile', (shelf.Request request) async {
        if (_status == _SyncStatus.applying) {
          return shelf.Response(
            HttpStatus.conflict,
            body: jsonEncode({'ok': false, 'status': 'applying'}),
            headers: {'content-type': 'application/json'},
          );
        }
        final url = await _readProfileUrl(request);
        if (url == null) {
          return shelf.Response.badRequest(
            body: jsonEncode({'ok': false, 'error': 'invalid url'}),
            headers: {'content-type': 'application/json'},
          );
        }
        _setStatus(_SyncStatus.applying);
        // Apply in the background; the phone watches progress via /status.
        unawaited(_applyReceivedUrl(url));
        return shelf.Response.ok(
          jsonEncode({'ok': true}),
          headers: {'content-type': 'application/json'},
        );
      });

      _server = await shelf_io.serve(router.call, ip, _syncPort);
      commonPrint.log(
        'TV sync server started at http://${_server?.address.host}:${_server?.port}',
      );

      if (!mounted) return;
      // Plain URL so the native phone camera offers to open it. The app's
      // scanner also understands this form (extracts host:port).
      setState(() {
        _qrData = 'http://$ip:$_syncPort/';
        _isLoading = false;
      });
    } catch (e) {
      commonPrint.log('Error starting TV sync server: $e');
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<String?> _readProfileUrl(shelf.Request request) async {
    try {
      final body = await request.readAsString();
      final payload = jsonDecode(body);
      if (payload is! Map<String, dynamic>) return null;
      final url = payload['url'];
      if (url is! String || url.trim().isEmpty) return null;
      return url.trim();
    } catch (e) {
      commonPrint.log('Invalid TV sync request: $e');
      return null;
    }
  }

  Future<void> _applyReceivedUrl(String url) async {
    try {
      await globalState.appController.addProfileFromUrlForSync(url);
      _setStatus(_SyncStatus.success);
      // Let the phone's poll and the TV both show success briefly, then close.
      await Future.delayed(const Duration(milliseconds: 1600));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      commonPrint.log('TV sync apply failed: $e');
      // Keep the server alive so the phone sees the error and can retry.
      _setStatus(_SyncStatus.error, e.toString());
    }
  }

  void _setStatus(_SyncStatus status, [String? message]) {
    if (!mounted) {
      _status = status;
      _statusMessage = message;
      return;
    }
    setState(() {
      _status = status;
      _statusMessage = message;
    });
  }

  @override
  void dispose() {
    _server?.close(force: true);
    commonPrint.log('TV sync server stopped');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(appLocalizations.receiveSubscriptionTitle),
      content: SizedBox(
        width: 300,
        height: 320,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _qrData == null
                ? const Center(child: Text('Could not get IP address'))
                : _buildBody(context),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(appLocalizations.cancel),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_status) {
      case _SyncStatus.waiting:
        return _buildQr(context);
      case _SyncStatus.applying:
        return _buildStatus(
          context,
          const SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(),
          ),
          'Получаю профиль с телефона…',
        );
      case _SyncStatus.success:
        return _buildStatus(
          context,
          Icon(Icons.check_circle_outline,
              size: 56, color: context.colorScheme.primary),
          'Профиль добавлен',
        );
      case _SyncStatus.error:
        return _buildStatus(
          context,
          Icon(Icons.error_outline,
              size: 56, color: context.colorScheme.error),
          'Не удалось добавить профиль',
          detail: _statusMessage,
        );
    }
  }

  Widget _buildQr(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Expanded(
          child: QrImageView(
            data: _qrData!,
            version: QrVersions.auto,
            size: 240.0,
            backgroundColor: Colors.transparent,
            dataModuleStyle: QrDataModuleStyle(
              color: theme.colorScheme.onSurface,
              dataModuleShape: QrDataModuleShape.square,
            ),
            eyeStyle: QrEyeStyle(
              color: theme.colorScheme.onSurface,
              eyeShape: QrEyeShape.square,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Отсканируйте код камерой телефона',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildStatus(
    BuildContext context,
    Widget icon,
    String title, {
    String? detail,
  }) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(height: 20),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          if (detail != null && detail.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Static, self-contained landing page. Relative endpoints keep every request
  // same-origin with the TV. Raw string: `$` is literal (no Dart interpolation).
  static const String _pageHtml = r'''<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>FlClashX — подписка на ТВ</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh;
    display: flex; align-items: center; justify-content: center;
    background: #0e0f13; color: #e9eaee;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    padding: 24px;
  }
  .card {
    width: 100%; max-width: 440px;
    background: #181a20; border: 1px solid #262a33; border-radius: 20px;
    padding: 28px 22px; box-shadow: 0 12px 40px rgba(0,0,0,.45);
  }
  h1 { font-size: 20px; margin: 0 0 6px; }
  p.sub { margin: 0 0 20px; color: #9aa0ab; font-size: 14px; line-height: 1.4; }
  textarea {
    width: 100%; min-height: 88px; resize: vertical;
    background: #0e0f13; color: #e9eaee;
    border: 1px solid #2d323c; border-radius: 12px;
    padding: 14px; font-size: 15px; outline: none;
    -webkit-appearance: none;
  }
  textarea:focus { border-color: #5b8cff; }
  .row { display: flex; gap: 10px; margin-top: 14px; }
  button {
    flex: 1; border: 0; border-radius: 12px;
    padding: 14px 16px; font-size: 15px; font-weight: 600;
    cursor: pointer; transition: opacity .15s, background .15s;
  }
  button:disabled { opacity: .5; }
  .primary { background: #5b8cff; color: #fff; }
  .ghost { background: #23262e; color: #cdd2db; flex: 0 0 auto; }
  #msg {
    margin-top: 18px; min-height: 22px; text-align: center;
    font-size: 14.5px; line-height: 1.4; color: #b9bfca;
  }
  #msg.ok { color: #56d18a; }
  #msg.err { color: #ff6b6b; }
</style>
</head>
<body>
  <div class="card">
    <h1>Подписка на телевизор</h1>
    <p class="sub">Вставьте ссылку на подписку и нажмите «Отправить» — она появится на телевизоре автоматически.</p>
    <textarea id="url" inputmode="url" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="https://..."></textarea>
    <div class="row">
      <button class="ghost" id="paste" onclick="paste()">Вставить</button>
      <button class="primary" id="send" onclick="send()">Отправить</button>
    </div>
    <div id="msg"></div>
  </div>
<script>
  var q = function(s){ return document.querySelector(s); };
  function setMsg(t, cls){ var m = q('#msg'); m.textContent = t; m.className = cls || ''; }
  function paste(){
    if (navigator.clipboard && navigator.clipboard.readText) {
      navigator.clipboard.readText().then(function(t){ if(t) q('#url').value = t; })
        .catch(function(){ q('#url').focus(); });
    } else { q('#url').focus(); }
  }
  function send(){
    var url = q('#url').value.trim();
    if (!url){ setMsg('Вставьте ссылку подписки', 'err'); return; }
    q('#send').disabled = true;
    setMsg('Отправляю…');
    fetch('/add-profile', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ url: url })
    }).then(function(r){
      return r.json().catch(function(){ return {}; }).then(function(j){
        if (!r.ok || !j.ok){ setMsg('Телевизор отклонил ссылку', 'err'); q('#send').disabled = false; return; }
        poll();
      });
    }).catch(function(){
      setMsg('Не удалось связаться с телевизором', 'err'); q('#send').disabled = false;
    });
  }
  function poll(){
    fetch('/status').then(function(r){ return r.json(); }).then(function(j){
      if (j.status === 'applying'){ setMsg('Телевизор добавляет профиль…'); setTimeout(poll, 800); }
      else if (j.status === 'success'){ setMsg('✅ Готово! Профиль добавлен на телевизор', 'ok'); }
      else if (j.status === 'error'){ setMsg('❌ Ошибка: ' + (j.message || 'не удалось добавить'), 'err'); q('#send').disabled = false; }
      else { setMsg('Телевизор получил ссылку…'); setTimeout(poll, 800); }
    }).catch(function(){ setMsg('Связь с телевизором потеряна', 'err'); q('#send').disabled = false; });
  }
</script>
</body>
</html>''';
}
