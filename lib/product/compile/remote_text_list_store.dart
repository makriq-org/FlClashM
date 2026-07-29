import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

typedef RemoteTextListDownloader = Future<String?> Function(Uri url,
    {required Duration timeout});

@immutable
class RemoteTextList {
  const RemoteTextList({required this.body, required this.fetchedAt});

  final String body;
  final DateTime fetchedAt;
}

/// Shared bounded, stale-on-error cache used by profile remote-list sources.
class RemoteTextListStore {
  RemoteTextListStore({
    required this.cacheDirectoryPath,
    required this.download,
    this.batchTimeout = const Duration(seconds: 20),
    this.concurrency = 8,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final String cacheDirectoryPath;
  final RemoteTextListDownloader download;
  final Duration batchTimeout;
  final int concurrency;
  final DateTime Function() now;

  Future<Map<Uri, RemoteTextList>> resolve(
    List<Uri> urls, {
    required Duration refresh,
  }) async {
    final result = <Uri, RemoteTextList>{};
    final stale = <Uri, RemoteTextList?>{};
    for (final url in urls) {
      if (result.containsKey(url) || stale.containsKey(url)) continue;
      final cached = await _read(url);
      if (cached != null && now().difference(cached.fetchedAt) < refresh) {
        result[url] = cached;
      } else {
        stale[url] = cached;
      }
    }
    if (stale.isEmpty) return result;

    final elapsed = Stopwatch()..start();
    Duration remaining() {
      final value = batchTimeout - elapsed.elapsed;
      return value.isNegative ? Duration.zero : value;
    }

    final pending = stale.keys.toList(growable: false);
    final bodies = List<String?>.filled(pending.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= pending.length) return;
        final budget = remaining();
        if (budget == Duration.zero) return;
        try {
          bodies[index] = await download(
            pending[index],
            timeout: budget,
          ).timeout(budget);
        } catch (_) {
          bodies[index] = null;
        }
      }
    }

    await Future.wait(
      List.generate(
        pending.length < concurrency ? pending.length : concurrency,
        (_) => worker(),
      ),
    );
    for (var index = 0; index < pending.length; index++) {
      final url = pending[index];
      final body = bodies[index];
      if (body == null) {
        final cached = stale[url];
        if (cached != null) result[url] = cached;
        continue;
      }
      final value = RemoteTextList(body: body, fetchedAt: now());
      await _write(url, value);
      result[url] = value;
    }
    return result;
  }

  File _file(Uri url) {
    final key = sha256.convert(utf8.encode(url.toString())).toString();
    return File('$cacheDirectoryPath${Platform.pathSeparator}$key.json');
  }

  Future<RemoteTextList?> _read(Uri url) async {
    final file = _file(url);
    if (!file.existsSync()) return null;
    try {
      final value = json.decode(await file.readAsString());
      if (value is! Map) return null;
      final body = value['body'];
      final fetchedAt = DateTime.tryParse('${value['fetchedAt']}');
      return body is String && fetchedAt != null
          ? RemoteTextList(body: body, fetchedAt: fetchedAt)
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(Uri url, RemoteTextList value) async {
    try {
      await Directory(cacheDirectoryPath).create(recursive: true);
      await _file(url).writeAsString(
        json.encode({
          'url': url.toString(),
          'fetchedAt': value.fetchedAt.toIso8601String(),
          'body': value.body,
        }),
        flush: true,
      );
    } catch (_) {
      // A cache write must not turn a successful fetch into a profile error.
    }
  }
}
