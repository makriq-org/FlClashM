import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flclashm/common/common.dart';
import 'package:flclashm/models/models.dart';
import 'package:flclashm/state.dart';
import 'package:flutter/cupertino.dart';

class Request {
  Request() {
    _dio = Dio(
      BaseOptions(
        headers: {
          "User-Agent": browserUa,
        },
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
    _clashDio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
      final client = HttpClient();
      client.findProxy = (uri) {
        client.userAgent = globalState.ua;
        return FlClashHttpOverrides.handleFindProxy(uri);
      };
      return client;
    });
    _ipDio = Dio();
    _ipDio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
      final client = HttpClient();
      client.findProxy = (uri) {
        client.userAgent = globalState.ua;
        return FlClashHttpOverrides.handleFindProxy(
          uri,
          forceMixedPort: true,
        );
      };
      return client;
    });
  }
  late final Dio _dio;
  late final Dio _clashDio;
  late final Dio _ipDio;
  String? userAgent;

  Future<Response<Uint8List>> getFileResponseForUrl(
    String rawUrl, {
    Map<String, dynamic>? headers,
  }) async {
    final url = rawUrl.normalizeUrlCredentials;
    final requestHeaders = headers ?? {};
    requestHeaders['User-Agent'] = globalState.ua;

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
    final response = await _clashDio.get(
      url,
      options: Options(
        responseType: ResponseType.plain,
      ),
    );
    return response;
  }

  Future<MemoryImage?> getImage(String url) async {
    if (url.isEmpty) return null;
    final response = await _dio.get<Uint8List>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
      ),
    );
    final data = response.data;
    if (data == null) return null;
    return MemoryImage(data);
  }

  Future<Map<String, dynamic>?> checkForUpdate() async {
    final response = await _dio.get(
      "https://api.github.com/repos/$repository/releases/latest",
      options: Options(
        responseType: ResponseType.json,
      ),
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
      String currentCoreVersion) async {
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
      if (remote == current) return null;
      return release as Map<String, dynamic>;
    }
    return null;
  }

  Future<String?> downloadCoreUpdate(
    String downloadUrl,
    String targetPath, {
    void Function(int received, int total)? onProgress,
  }) async {
    try {
      final tmpPath = '$targetPath.tmp';
      await _dio.download(
        downloadUrl,
        tmpPath,
        onReceiveProgress: onProgress,
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
            options: Options(
              responseType: ResponseType.plain,
            ),
          )
          .timeout(
            const Duration(
              milliseconds: 2000,
            ),
          );
      if (response.statusCode != HttpStatus.ok) {
        return false;
      }
      return (response.data as String) == globalState.coreSHA256;
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
            options: Options(
              responseType: ResponseType.plain,
            ),
          )
          .timeout(
            const Duration(
              milliseconds: 2000,
            ),
          );
      if (response.statusCode != HttpStatus.ok) {
        return false;
      }
      final data = response.data as String;
      return data.isEmpty;
    } catch (_) {
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

  Future<Map<String, dynamic>?> getCoreVersion() async {
    try {
      final addr = globalState.effectiveExternalController.value;
      if (addr.isEmpty) return null;
      final response = await _dio
          .get<Map<String, dynamic>>(
            "http://$addr/version",
            options: Options(
              responseType: ResponseType.json,
            ),
          )
          .timeout(const Duration(seconds: 2));

      if (response.statusCode != HttpStatus.ok) return null;
      return response.data;
    } catch (_) {
      return null;
    }
  }
}

final request = Request();
