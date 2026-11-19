import 'dart:async';

import 'package:flutter/foundation.dart';

/// Сколько переходов по `Location` допускается при чтении подписанного
/// документа. Каждый переход проверяется отдельно, поэтому малое число
/// ограничивает и цепочку, и время ответа.
const appUpdateMaxRedirects = 4;

/// Пределы для подписанного указателя каталога и его `.sig`.
const appUpdateManifestMaxBytes = 256 * 1024;
const appUpdateSignatureMaxBytes = 4 * 1024;

/// Общий срок на один документ: медленное зеркало не может держать проверку
/// обновлений бесконечно.
const appUpdateFetchDeadline = Duration(seconds: 20);

/// Наибольший APK, который апдейтер вообще готов скачать.
const appUpdateMaxApkBytes = 256 * 1024 * 1024;

/// Один ответ зеркала без следования редиректам: решение о следующем адресе
/// принимает [fetchAppUpdateDocument], проверив его отдельно.
@immutable
class AppUpdateHttpResponse {
  const AppUpdateHttpResponse({
    required this.statusCode,
    this.location,
    this.body = const [],
  });

  final int statusCode;
  final Uri? location;
  final List<int> body;

  bool get isSuccess => statusCode == 200;
}

class AppUpdateFetchException implements Exception {
  const AppUpdateFetchException(this.message);

  final String message;

  @override
  String toString() => 'app update fetch rejected: $message';
}

/// Отмена загрузки обновления. Прячет `CancelToken` от вызывающих слоёв,
/// чтобы Dio не протекал в сервис обновлений и его тесты.
class AppUpdateDownloadCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void Function() addListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

/// Бросается вместо ошибки загрузки, когда пользователь сам нажал «Отмена»:
/// такой сценарий не должен показывать окно с ошибкой установки.
class AppUpdateDownloadCancelledException implements Exception {
  const AppUpdateDownloadCancelledException();

  @override
  String toString() => 'App update download was cancelled by the user.';
}

abstract interface class AppUpdateHttpClient {
  /// Один запрос без редиректов. Тело читается только до [maxBytes].
  Future<AppUpdateHttpResponse> open(
    Uri url, {
    required int maxBytes,
    required Duration deadline,
  });

  Future<List<dynamic>> readJsonList(String url);

  Future<String?> readText(String url);

  Future<void> download(
    String url,
    String targetPath, {
    void Function(int received, int total)? onReceiveProgress,
    AppUpdateDownloadCancellation? cancellation,
    int? expectedLength,
  });
}

/// Зеркало каталога обновлений: только HTTPS, без учётных данных во фрагменте
/// адреса и без нестандартного порта. Подпись содержимого всё равно
/// проверяется отдельно — это ограничение канала, а не источник доверия.
bool isAppUpdateHttpsUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment &&
    (!uri.hasPort || uri.port == 443) &&
    uri.path.isNotEmpty;

/// Читает документ по адресу, проверяя каждый переход по [isAllowed].
/// Ответ сверху ограничен [maxBytes] и общим сроком [deadline].
Future<Uint8List> fetchAppUpdateDocument(
  AppUpdateHttpClient client,
  Uri url, {
  required int maxBytes,
  bool Function(Uri uri) isAllowed = isAppUpdateHttpsUri,
  Duration deadline = appUpdateFetchDeadline,
}) async {
  var current = url;
  final elapsed = Stopwatch()..start();
  for (var hop = 0; hop <= appUpdateMaxRedirects; hop++) {
    if (!isAllowed(current)) {
      throw AppUpdateFetchException('untrusted address $current');
    }
    final remaining = deadline - elapsed.elapsed;
    if (remaining <= Duration.zero) {
      throw TimeoutException('Update document deadline exceeded', deadline);
    }
    final response = await client
        .open(current, maxBytes: maxBytes, deadline: remaining)
        .timeout(remaining);
    if (response.isSuccess) {
      if (response.body.length > maxBytes) {
        throw const AppUpdateFetchException('document too large');
      }
      return Uint8List.fromList(response.body);
    }
    final location = response.location;
    if (response.statusCode < 300 ||
        response.statusCode >= 400 ||
        location == null) {
      throw AppUpdateFetchException('HTTP ${response.statusCode} for $current');
    }
    current = current.resolveUri(location);
  }
  throw AppUpdateFetchException('too many redirects for $url');
}
