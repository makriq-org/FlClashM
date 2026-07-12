import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

typedef SocksConnectivityProbe = Future<bool> Function({
  required String host,
  required int port,
  required Uri url,
  required Duration timeout,
});

const connectivityCheckMaxUrls = 16;
const connectivityCheckMaxRequests = 32;
const connectivityCheckMaxConcurrency = 16;
const connectivityCheckMaxTimeout = Duration(seconds: 60);
const connectivityCheckMaxStartupTimeout = Duration(minutes: 5);

@immutable
class ConnectivityCheckConfig {
  const ConnectivityCheckConfig({
    this.urls = const [],
    this.required = false,
    this.timeout = const Duration(seconds: 5),
    this.startupTimeout = const Duration(seconds: 30),
    this.retryInterval = const Duration(seconds: 1),
    this.requests = 1,
    this.concurrency = 1,
    this.minSuccessRatio,
  });

  final List<Uri> urls;
  final bool required;
  final Duration timeout;
  final Duration startupTimeout;
  final Duration retryInterval;
  final int requests;
  final int concurrency;
  final double? minSuccessRatio;

  ConnectivityCheckConfig copyWith({Duration? startupTimeout}) =>
      ConnectivityCheckConfig(
        urls: urls,
        required: required,
        timeout: timeout,
        startupTimeout: startupTimeout ?? this.startupTimeout,
        retryInterval: retryInterval,
        requests: requests,
        concurrency: concurrency,
        minSuccessRatio: minSuccessRatio,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'urls': urls.map((url) => url.toString()).toList(growable: false),
        'required': required,
        'timeout': timeout.inSeconds,
        'startup-timeout': startupTimeout.inSeconds,
        'retry-interval': retryInterval.inSeconds,
        'requests': requests,
        'concurrency': concurrency,
        if (minSuccessRatio != null) 'min-success-ratio': minSuccessRatio,
      };
}

bool isSafeConnectivityUri(Uri uri) {
  try {
    if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) return false;
  } on FormatException {
    return false;
  }
  if ((uri.scheme != 'http' && uri.scheme != 'https') ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    return false;
  }
  final host = uri.host.toLowerCase();
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal') ||
      host.endsWith('.home.arpa')) {
    return false;
  }
  final address = InternetAddress.tryParse(host);
  return address == null || isPublicInternetAddress(address);
}

bool isPublicInternetAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    final first = bytes[0];
    final second = bytes[1];
    return first != 0 &&
        first != 10 &&
        first != 127 &&
        first < 224 &&
        !(first == 100 && second >= 64 && second <= 127) &&
        !(first == 169 && second == 254) &&
        !(first == 172 && second >= 16 && second <= 31) &&
        !(first == 192 && second == 0) &&
        !(first == 192 && second == 168) &&
        !(first == 198 && (second == 18 || second == 19));
  }
  if (bytes.every((value) => value == 0) ||
      bytes.sublist(0, 15).every((value) => value == 0) && bytes[15] == 1) {
    return false;
  }
  final isMappedIpv4 = bytes.sublist(0, 10).every((value) => value == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff;
  if (isMappedIpv4) {
    return isPublicInternetAddress(
      InternetAddress.fromRawAddress(bytes.sublist(12)),
    );
  }
  return (bytes[0] & 0xe0) == 0x20 &&
      (bytes[0] & 0xfe) != 0xfc &&
      !(bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) &&
      bytes[0] != 0xff &&
      !(bytes[0] == 0x20 &&
          bytes[1] == 0x01 &&
          bytes[2] == 0x0d &&
          bytes[3] == 0xb8);
}

class ConnectivityChecker {
  const ConnectivityChecker({
    this.probe = checkUrlViaSocks,
    this.delay = _delay,
  });

  final SocksConnectivityProbe probe;
  final Future<void> Function(Duration duration) delay;

  Future<bool> checkOnce({
    required String host,
    required int port,
    required ConnectivityCheckConfig config,
  }) async {
    final checks = <Uri>[
      for (final url in config.urls)
        for (var index = 0; index < config.requests; index++) url,
    ];
    if (checks.isEmpty) {
      return false;
    }
    var next = 0;
    var successes = 0;
    final workers =
        config.concurrency < checks.length ? config.concurrency : checks.length;

    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= checks.length) return;
        if (await probe(
          host: host,
          port: port,
          url: checks[index],
          timeout: config.timeout,
        )) {
          successes++;
        }
      }
    }

    await Future.wait([for (var index = 0; index < workers; index++) worker()]);
    final ratio = config.minSuccessRatio;
    return ratio == null ? successes > 0 : successes / checks.length >= ratio;
  }

  Future<bool> checkUntilDeadline({
    required String host,
    required int port,
    required ConnectivityCheckConfig config,
    required Future<bool> Function() isProcessRunning,
  }) async {
    final stopwatch = Stopwatch()..start();
    while (true) {
      if (!await isProcessRunning()) return false;
      final checkBudget = config.startupTimeout - stopwatch.elapsed;
      if (checkBudget <= Duration.zero) return false;
      final passed = await checkOnce(host: host, port: port, config: config)
          .timeout(checkBudget, onTimeout: () => false);
      if (passed) return true;
      final remaining = config.startupTimeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) return false;
      await delay(
          config.retryInterval < remaining ? config.retryInterval : remaining);
    }
  }

  static Future<void> _delay(Duration duration) => Future.delayed(duration);
}

Future<bool> checkUrlViaSocks({
  required String host,
  required int port,
  required Uri url,
  required Duration timeout,
}) async {
  Socket? socket;
  try {
    if (!isSafeConnectivityUri(url)) return false;
    final addresses = await InternetAddress.lookup(url.host).timeout(timeout);
    if (addresses.isEmpty ||
        addresses.any((item) => !isPublicInternetAddress(item))) {
      return false;
    }
    socket = await Socket.connect(host, port, timeout: timeout);
    var reader = _SocketByteReader(socket);
    await _performSocksGreeting(socket, reader, timeout);
    final targetPort =
        url.hasPort ? url.port : (url.scheme == 'http' ? 80 : 443);
    await _performSocksConnect(
      socket,
      reader,
      addresses.first.address,
      targetPort,
      timeout,
    );
    if (url.scheme == 'https') {
      socket =
          await SecureSocket.secure(socket, host: url.host).timeout(timeout);
      reader = _SocketByteReader(socket);
    }
    socket.add(utf8.encode(_buildHttpRequest(url, targetPort)));
    await socket.flush().timeout(timeout);
    final watch = Stopwatch()..start();
    final statusLine = await reader.readLine(
      timeout: timeout,
      maxLength: 4096,
      elapsed: () => watch.elapsed,
    );
    return RegExp(r'^HTTP/\d\.\d\s+[1-5]\d{2}\b').hasMatch(statusLine.trim());
  } on Object {
    return false;
  } finally {
    socket?.destroy();
  }
}

Future<void> _performSocksGreeting(
  Socket socket,
  _SocketByteReader reader,
  Duration timeout,
) async {
  socket.add(const [0x05, 0x01, 0x00]);
  await socket.flush().timeout(timeout);
  final response = await reader.readBytes(2, timeout);
  if (response[0] != 0x05 || response[1] != 0x00) {
    throw const SocketException('SOCKS5 greeting failed');
  }
}

Future<void> _performSocksConnect(
  Socket socket,
  _SocketByteReader reader,
  String targetHost,
  int targetPort,
  Duration timeout,
) async {
  socket.add(_buildSocksConnectRequest(targetHost, targetPort));
  await socket.flush().timeout(timeout);
  final header = await reader.readBytes(4, timeout);
  if (header[0] != 0x05 || header[1] != 0x00 || header[2] != 0x00) {
    throw const SocketException('SOCKS5 connect failed');
  }
  switch (header[3]) {
    case 0x01:
      await reader.readBytes(4, timeout);
      break;
    case 0x03:
      final length = (await reader.readBytes(1, timeout)).single;
      await reader.readBytes(length, timeout);
      break;
    case 0x04:
      await reader.readBytes(16, timeout);
      break;
    default:
      throw const SocketException('SOCKS5 returned unknown address type');
  }
  await reader.readBytes(2, timeout);
}

List<int> _buildSocksConnectRequest(String host, int port) {
  final address = InternetAddress.tryParse(host);
  if (address == null) {
    throw const SocketException('Resolved address is invalid');
  }
  final addressType = address.type == InternetAddressType.IPv4 ? 0x01 : 0x04;
  return [
    0x05,
    0x01,
    0x00,
    addressType,
    ...address.rawAddress,
    (port >> 8) & 0xff,
    port & 0xff,
  ];
}

String _buildHttpRequest(Uri url, int targetPort) {
  final target = url.path.isEmpty
      ? '/${url.hasQuery ? '?${url.query}' : ''}'
      : '${url.path}${url.hasQuery ? '?${url.query}' : ''}';
  final host = url.host.contains(':') ? '[${url.host}]' : url.host;
  final defaultPort = url.scheme == 'http' ? 80 : 443;
  final authority =
      url.hasPort && targetPort != defaultPort ? '$host:$targetPort' : host;
  return 'HEAD $target HTTP/1.1\r\nHost: $authority\r\nConnection: close\r\n\r\n';
}

class _SocketByteReader {
  _SocketByteReader(Socket socket)
      : _iterator = StreamIterator<List<int>>(socket);

  final StreamIterator<List<int>> _iterator;
  final List<int> _buffer = [];

  Future<List<int>> readBytes(int count, Duration timeout) async {
    while (_buffer.length < count) {
      if (!await _iterator.moveNext().timeout(timeout)) {
        throw const SocketException('Unexpected end of socket');
      }
      _buffer.addAll(_iterator.current);
    }
    final result = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return result;
  }

  Future<String> readLine({
    required Duration timeout,
    required int maxLength,
    required Duration Function() elapsed,
  }) async {
    while (true) {
      final newline = _buffer.indexOf(0x0a);
      if (newline >= 0) {
        final result = _buffer.sublist(0, newline + 1);
        _buffer.removeRange(0, newline + 1);
        return utf8.decode(result, allowMalformed: true);
      }
      if (_buffer.length >= maxLength) {
        throw const SocketException('HTTP status line is too long');
      }
      final remaining = timeout - elapsed();
      if (remaining <= Duration.zero ||
          !await _iterator.moveNext().timeout(remaining)) {
        throw const SocketException('Unexpected end of HTTP response');
      }
      _buffer.addAll(_iterator.current);
    }
  }
}
