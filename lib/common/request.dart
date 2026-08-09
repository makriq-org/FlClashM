import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flclashx/clash/clash.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/state.dart';
import 'package:flutter/cupertino.dart';

class Request {
  Request() {
    _dio = Dio(
      BaseOptions(
        headers: {"User-Agent": browserUa},
        // Without these a profile/subscription fetch over a half-dead uplink
        // (mobile network, doze-restricted background) hangs forever: the card
        // spins indefinitely and the auto-update chain stalls until app restart.
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );
    _clashDio = Dio(
      BaseOptions(
        // Only cap connection setup globally so a dead/blackholed exit node fails
        // fast instead of hanging the IP check. Receive time is left unbounded
        // here (large proxied downloads use this same client) and capped
        // per-request in checkIp instead.
        connectTimeout: const Duration(seconds: 5),
      ),
    );
    _clashDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (uri) {
          client.userAgent = globalState.ua;
          return FlClashHttpOverrides.handleFindProxy(uri);
        };
        return client;
      },
    );
  }
  late final Dio _dio;
  late final Dio _clashDio;
  String? userAgent;

  bool get _shouldUseTunnelTransport => globalState.isStart;

  Future<Response<Uint8List>> _getTunnelResponse(
    String url, {
    required Map<String, dynamic> headers,
    Duration timeout = const Duration(seconds: 60),
    int maxResponseLength = 16 << 20,
  }) async {
    final response = await clashCore.tunnelHTTPRequest({
      'url': url,
      'method': 'GET',
      'headers': headers.map((key, value) => MapEntry(key, '$value')),
      'timeout-millis': timeout.inMilliseconds,
      'max-response-len': maxResponseLength,
    });
    final error = response['error']?.toString();
    final requestOptions = RequestOptions(path: url);
    if (error != null && error.isNotEmpty) {
      throw DioException(
        requestOptions: requestOptions,
        type: DioExceptionType.connectionError,
        error: error,
      );
    }
    final body = response['body'];
    if (body is! String) {
      throw DioException(
        requestOptions: requestOptions,
        type: DioExceptionType.badResponse,
        error: 'Tunnel HTTP response has no body.',
      );
    }
    final rawHeaders = response['headers'];
    final responseHeaders = <String, List<String>>{};
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final value = entry.value;
        responseHeaders['${entry.key}'] = value is List
            ? value.map((item) => '$item').toList(growable: false)
            : ['$value'];
      }
    }
    return Response<Uint8List>(
      requestOptions: requestOptions,
      data: Uint8List.fromList(base64Decode(body)),
      statusCode: response['status-code'] as int?,
      headers: Headers.fromMap(responseHeaders),
    );
  }

  Future<Response<Uint8List>> getFileResponseForUrl(
    String rawUrl, {
    Map<String, dynamic>? headers,
  }) async {
    final url = rawUrl.normalizeUrlCredentials;
    final requestHeaders = headers ?? {};
    requestHeaders['User-Agent'] = globalState.ua;

    if (_shouldUseTunnelTransport) {
      return _getTunnelResponse(url, headers: requestHeaders);
    }

    final dio = _dio;

    final firstResponse = await dio.get<Uint8List>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        headers: requestHeaders,
        followRedirects: false,
        validateStatus: (status) => status != null && status < 400,
      ),
    );

    if (firstResponse.isRedirect) {
      final newUrl = firstResponse.headers.value('location');
      if (newUrl == null) {
        throw Exception('Redirect detected, but no location header was found.');
      }

      final finalResponse = await dio.get<Uint8List>(
        newUrl,
        options: Options(
          responseType: ResponseType.bytes,
          headers: requestHeaders,
          followRedirects: true,
          maxRedirects: 5,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      return finalResponse;
    }
    return firstResponse;
  }

  Future<Response> getTextResponseForUrl(String url) async {
    if (_shouldUseTunnelTransport) {
      final response = await _getTunnelResponse(
        url,
        headers: {'User-Agent': globalState.ua},
      );
      return Response<String>(
        requestOptions: response.requestOptions,
        data: utf8.decode(response.data!, allowMalformed: true),
        statusCode: response.statusCode,
        headers: response.headers,
      );
    }
    final response = await _clashDio.get(
      url,
      options: Options(responseType: ResponseType.plain),
    );
    return response;
  }

  Future<MemoryImage?> getImage(String url) async {
    if (url.isEmpty) return null;
    if (_shouldUseTunnelTransport) {
      final response = await _getTunnelResponse(
        url,
        headers: {'User-Agent': globalState.ua},
      );
      return response.data == null ? null : MemoryImage(response.data!);
    }
    final response = await _dio.get<Uint8List>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final data = response.data;
    if (data == null) return null;
    return MemoryImage(data);
  }

  Future<Map<String, dynamic>?> checkForUpdate() async {
    if (_shouldUseTunnelTransport) {
      final response = await _getTunnelResponse(
        'https://api.github.com/repos/$repository/releases/latest',
        headers: {'User-Agent': globalState.ua},
      );
      if (response.statusCode != HttpStatus.ok || response.data == null) {
        return null;
      }
      final data =
          json.decode(utf8.decode(response.data!)) as Map<String, dynamic>;
      final remoteVersion = data['tag_name'];
      final version = globalState.packageInfo.version;
      return utils.compareVersions(remoteVersion.replaceAll('v', ''), version) >
              0
          ? data
          : null;
    }
    final response = await _dio.get(
      "https://api.github.com/repos/$repository/releases/latest",
      options: Options(responseType: ResponseType.json),
    );
    if (response.statusCode != 200) return null;
    final data = response.data as Map<String, dynamic>;
    final remoteVersion = data['tag_name'];
    final version = globalState.packageInfo.version;
    final hasUpdate =
        utils.compareVersions(remoteVersion.replaceAll('v', ''), version) > 0;
    if (!hasUpdate) return null;
    return data;
  }

  Future<Map<String, dynamic>?> checkForCoreUpdate(
    String currentCoreVersion,
  ) async {
    if (_shouldUseTunnelTransport) {
      final response = await _getTunnelResponse(
        'https://api.github.com/repos/$repository/releases?per_page=20',
        headers: {'User-Agent': globalState.ua},
      );
      if (response.statusCode != HttpStatus.ok || response.data == null) {
        return null;
      }
      final releases =
          json.decode(utf8.decode(response.data!)) as List<dynamic>;
      final current = currentCoreVersion.replaceAll(RegExp(r'^v'), '');
      for (final release in releases) {
        final tag = (release as Map)['tag_name'] as String? ?? '';
        if (!tag.startsWith('core-')) continue;
        final remote =
            tag.replaceFirst('core-', '').replaceAll(RegExp(r'^v'), '');
        if (utils.compareVersions(remote, current) <= 0) return null;
        return Map<String, dynamic>.from(release);
      }
      return null;
    }
    final response = await _dio.get(
      "https://api.github.com/repos/$repository/releases",
      options: Options(responseType: ResponseType.json),
      queryParameters: {'per_page': 20},
    );
    if (response.statusCode != 200) return null;
    final current = currentCoreVersion.replaceAll(RegExp(r'^v'), '');
    final releases = response.data as List<dynamic>;
    for (final release in releases) {
      final tag = release['tag_name'] as String? ?? '';
      if (!tag.startsWith('core-')) continue;
      final remote =
          tag.replaceFirst('core-', '').replaceAll(RegExp(r'^v'), '');
      // Strictly newer only: a locally built core can be ahead of the newest
      // core-* release, and offering it back would be a silent downgrade.
      if (utils.compareVersions(remote, current) <= 0) return null;
      return release as Map<String, dynamic>;
    }
    return null;
  }

  Future<String?> downloadCoreUpdate(
    String downloadUrl,
    String targetPath, {
    void Function(int received, int total)? onProgress,
    int? expectedLength,
  }) async {
    try {
      final tmpPath = '$targetPath.tmp';
      await downloadFileForUrl(
        downloadUrl,
        tmpPath,
        onProgress: onProgress,
        expectedLength: expectedLength,
      );
      final tmpFile = File(tmpPath);
      if (!tmpFile.existsSync()) return 'Download failed';
      final target = File(targetPath);
      if (target.existsSync()) target.deleteSync();
      await tmpFile.rename(targetPath);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> downloadFileForUrl(
    String url,
    String targetPath, {
    void Function(int received, int total)? onProgress,
    String? requestId,
    int? expectedLength,
  }) async {
    if (!_shouldUseTunnelTransport) {
      await _dio.download(
        url,
        targetPath,
        onReceiveProgress: onProgress,
      );
      return;
    }
    final target = File(targetPath);
    if (target.existsSync()) {
      target.deleteSync();
    }
    var lastReported = -1;
    void reportProgress() {
      if (onProgress == null) return;
      try {
        if (!target.existsSync()) return;
        final received = target.lengthSync();
        if (received == lastReported) return;
        lastReported = received;
        onProgress(received, expectedLength ?? -1);
      } on FileSystemException {
        // The downloader can replace or remove the temporary file between
        // existsSync() and lengthSync(); the next tick will observe its state.
      }
    }

    onProgress?.call(0, expectedLength ?? -1);
    final progressTimer = onProgress == null
        ? null
        : Timer.periodic(
            const Duration(milliseconds: 250),
            (_) => reportProgress(),
          );
    try {
      final response = await clashCore.tunnelHTTPRequest({
        'url': url,
        'method': 'GET',
        'headers': {'User-Agent': globalState.ua},
        'timeout-millis': const Duration(minutes: 5).inMilliseconds,
        'max-response-len': 256 << 20,
        'target-path': targetPath,
        if (requestId != null) 'request-id': requestId,
      });
      final error = response['error']?.toString();
      if (error != null && error.isNotEmpty) {
        throw DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.connectionError,
          error: error,
        );
      }
      final statusCode = response['status-code'] as int?;
      if (statusCode == null || statusCode < 200 || statusCode >= 300) {
        throw DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.badResponse,
          message: 'Tunnel download returned HTTP $statusCode.',
        );
      }
      final written = response['written-len'] as int? ?? 0;
      onProgress?.call(written, expectedLength ?? written);
    } catch (_) {
      if (target.existsSync()) {
        target.deleteSync();
      }
      rethrow;
    } finally {
      progressTimer?.cancel();
      reportProgress();
    }
  }

  // Tried in order, first success wins. All return a dead-simple JSON with an
  // IPv4 exit IP + country code:
  //   ip.sb     — `api-ipv4` host is A-only, so the exit is forced over IPv4
  //   ip-api.com — IPv4-only on the free tier
  //   ipinfo.io — plain {ip, country}, used as a last-resort fallback
  final Map<String, IpInfo Function(Map<String, dynamic>)> _ipInfoSources = {
    "https://api-ipv4.ip.sb/geoip": IpInfo.fromIpSbJson,
    "http://ip-api.com/json/?fields=status,countryCode,query":
        IpInfo.fromIpApiComJson,
    "https://ipinfo.io/json": IpInfo.fromIpInfoIoJson,
  };

  /// Resolve the exit IP by trying each source **sequentially**, stopping at the
  /// first success. A healthy primary therefore means exactly one request — not
  /// a parallel race that fires every source through the tunnel at once. Each
  /// source is bounded by a short receive timeout (plus the client-wide connect
  /// timeout) so a slow/dead node falls through to the next instead of hanging.
  Future<Result<IpInfo?>> checkIp({CancelToken? cancelToken}) async {
    for (final source in _ipInfoSources.entries) {
      if (cancelToken?.isCancelled ?? false) {
        return Result.error("cancelled");
      }
      try {
        if (_shouldUseTunnelTransport) {
          final response = await _getTunnelResponse(
            source.key,
            headers: {'User-Agent': globalState.ua},
            timeout: const Duration(seconds: 8),
            maxResponseLength: 1 << 20,
          );
          if (cancelToken?.isCancelled ?? false) {
            return Result.error('cancelled');
          }
          if (response.statusCode == HttpStatus.ok && response.data != null) {
            final data = json.decode(utf8.decode(response.data!));
            if (data is Map<String, dynamic>) {
              return Result.success(source.value(data));
            }
          }
        } else {
          final res = await _clashDio.get<Map<String, dynamic>>(
            source.key,
            cancelToken: cancelToken,
            options: Options(
            responseType: ResponseType.json,
            receiveTimeout: const Duration(seconds: 3),
          ),
        );
          if (res.statusCode == HttpStatus.ok && res.data != null) {
            return Result.success(source.value(res.data!));
          }
        }
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          return Result.error("cancelled");
        }
        // connect/receive timeout or bad status — fall through to the next source
      } catch (_) {
        // unexpected shape / parse failure — try the next source
      }
    }
    // Every source failed (offline, all timed out, or unparseable).
    return Result.success(null);
  }

  Future<bool> pingHelper() async {
    try {
      final response = await _dio
          .get(
            "http://$localhost:$helperPort/ping",
            options: Options(responseType: ResponseType.plain),
          )
          .timeout(const Duration(milliseconds: 2000));
      if (response.statusCode != HttpStatus.ok) {
        return false;
      }
      // Compare against the binary actually on disk, not the build-time
      // constant — a separately updated core is otherwise reported as a
      // helper mismatch forever.
      final diskHash = await coreUpdater.calcCoreSha256();
      return diskHash != null && (response.data as String) == diskHash;
    } catch (_) {
      return false;
    }
  }

  Future<bool> startCoreByHelper(String arg) async {
    try {
      final homeDirPath = await appPath.homeDirPath;
      final response = await _dio
          .post(
            "http://$localhost:$helperPort/start",
            data: json.encode({
              "path": appPath.corePath,
              "arg": arg,
              "home_dir": homeDirPath,
            }),
            options: Options(responseType: ResponseType.plain),
          )
          .timeout(const Duration(milliseconds: 2000));
      if (response.statusCode != HttpStatus.ok) {
        return false;
      }
      final data = response.data as String;
      return data.isEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Ask the SYSTEM helper to swap in the pending core update. Needed for
  /// per-machine installs (Program Files) where the unelevated app can't
  /// overwrite the binary itself. The helper stops the core, moves the file and
  /// refreshes the allow-list hash. Returns true only if it reports success.
  Future<bool> replaceCoreByHelper(
    String pendingPath,
    String targetPath,
  ) async {
    try {
      final response = await _dio
          .post(
            "http://$localhost:$helperPort/replace_core",
            data: json.encode({"pending": pendingPath, "target": targetPath}),
            options: Options(responseType: ResponseType.plain),
          )
          .timeout(const Duration(milliseconds: 10000));
      if (response.statusCode != HttpStatus.ok) return false;
      final data = response.data as String;
      if (data.isNotEmpty) {
        commonPrint.log("replaceCoreByHelper: $data");
        return false;
      }
      return true;
    } catch (e) {
      commonPrint.log("replaceCoreByHelper error: $e");
      return false;
    }
  }

  Future<bool> stopCoreByHelper() async {
    try {
      final response = await _dio
          .post(
            "http://$localhost:$helperPort/stop",
            options: Options(responseType: ResponseType.plain),
          )
          .timeout(const Duration(milliseconds: 2000));

      if (response.statusCode != HttpStatus.ok) return false;
      final data = response.data as String;
      return data.isEmpty;
    } catch (_) {
      return false;
    }
  }

}

final request = Request();
