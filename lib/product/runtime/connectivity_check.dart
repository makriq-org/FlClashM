import 'dart:io';

import 'package:flutter/foundation.dart';

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
  final rawHost = uri.host.toLowerCase();
  final host = rawHost.endsWith('.')
      ? rawHost.substring(0, rawHost.length - 1)
      : rawHost;
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
        !(first == 192 && second == 0 && (bytes[2] == 0 || bytes[2] == 2)) &&
        !(first == 192 && second == 168) &&
        !(first == 192 && second == 88 && bytes[2] == 99) &&
        !(first == 198 && (second == 18 || second == 19)) &&
        !(first == 198 && second == 51 && bytes[2] == 100) &&
        !(first == 203 && second == 0 && bytes[2] == 113);
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
