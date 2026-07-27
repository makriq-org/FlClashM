import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// Marker line staged into the generated resolver file wherever the profile
/// asked for `system`. The platform replaces it with the DNS servers of the
/// physical network and re-runs the de-duplication pass, so the Flutter process
/// never owns the system resolver list.
const stormDnsSystemDnsPlaceholder = '# @flclashm:system-dns';

/// Upstream `maxResolverHosts`: a single CIDR never expands past this many
/// addresses, and neither does the whole generated file.
const stormDnsMaxResolverHosts = 65536;

/// Slots held back for the system-DNS marker, which the platform expands after
/// this file is written. The app never learns how many resolvers the physical
/// network advertises, so a fixed reserve is what keeps the *rendered* file
/// inside [stormDnsMaxResolverHosts]. A handful of servers is the norm; 16 is
/// well past anything Android reports.
const stormDnsSystemDnsReservedHosts = 16;

const stormDnsDefaultResolverPort = 53;

/// Response cap and timeout for remote resolver lists.
const stormDnsRemoteListMaxBytes = 1024 * 1024;
const stormDnsRemoteListTimeout = Duration(seconds: 15);

@immutable
class StormDnsResolverEntry {
  const StormDnsResolverEntry({required this.ip, required this.port});

  final String ip;
  final int port;

  String get line => port == stormDnsDefaultResolverPort
      ? ip
      : (ip.contains(':') ? '[$ip]:$port' : '$ip:$port');

  @override
  bool operator ==(Object other) =>
      other is StormDnsResolverEntry && other.ip == ip && other.port == port;

  @override
  int get hashCode => Object.hash(ip, port);

  @override
  String toString() => line;
}

/// One element of the profile `resolvers` list, in declaration order.
sealed class StormDnsResolverSource {
  const StormDnsResolverSource();
}

class StormDnsSystemResolverSource extends StormDnsResolverSource {
  const StormDnsSystemResolverSource();
}

class StormDnsLiteralResolverSource extends StormDnsResolverSource {
  const StormDnsLiteralResolverSource(this.entries);

  final List<StormDnsResolverEntry> entries;
}

class StormDnsRemoteResolverSource extends StormDnsResolverSource {
  const StormDnsRemoteResolverSource(this.url);

  final Uri url;
}

/// A parsed IP prefix held as raw bytes so IPv4 and IPv6 share one code path.
@immutable
class _Prefix {
  const _Prefix({required this.address, required this.bits});

  final List<int> address;
  final int bits;

  List<int> masked() {
    final bytes = List<int>.from(address);
    var remaining = bits;
    for (var i = 0; i < bytes.length; i++) {
      if (remaining >= 8) {
        remaining -= 8;
        continue;
      }
      bytes[i] &= remaining == 0 ? 0 : (0xFF << (8 - remaining)) & 0xFF;
      remaining = 0;
    }
    return bytes;
  }
}

/// Either a single address or a prefix, mirroring upstream `resolverTarget`.
@immutable
class _ResolverTarget {
  const _ResolverTarget.address(List<int> value)
      : address = value,
        prefixValue = null;

  const _ResolverTarget.prefix(_Prefix value)
      : address = null,
        prefixValue = value;

  final List<int>? address;
  final _Prefix? prefixValue;
}

/// Parses the profile `resolvers` list into ordered sources.
///
/// Literal entries are strict: a malformed address in the profile is a config
/// error surfaced before the node starts. Lines inside a fetched remote list
/// are skipped instead, matching how StormDNS reads its resolver file.
class StormDnsResolverSourceParser {
  const StormDnsResolverSourceParser();

  List<StormDnsResolverSource> parse(Object? value, {required String label}) {
    if (value == null) {
      return const [StormDnsSystemResolverSource()];
    }
    if (value is! List) {
      throw FormatException('$label must be a list.');
    }
    if (value.isEmpty) {
      return const [StormDnsSystemResolverSource()];
    }

    final sources = <StormDnsResolverSource>[];
    for (final item in value) {
      if (item is! String || item.trim().isEmpty) {
        throw FormatException('$label must contain non-empty strings.');
      }
      final text = item.trim();
      if (text.toLowerCase() == 'system') {
        sources.add(const StormDnsSystemResolverSource());
        continue;
      }
      if (text.contains('://') || text.toLowerCase().startsWith('http')) {
        sources.add(StormDnsRemoteResolverSource(_requireListUrl(text, label)));
        continue;
      }
      final entries = expandLiteral(text);
      if (entries == null) {
        throw FormatException(
          '$label entry `$text` is not `system`, an IP address, an '
          'IP:port pair, a CIDR range, or an https:// list address.',
        );
      }
      if (entries.isEmpty) {
        throw FormatException(
          '$label entry `$text` expands past the $stormDnsMaxResolverHosts '
          'address limit.',
        );
      }
      sources.add(StormDnsLiteralResolverSource(entries));
    }
    return List<StormDnsResolverSource>.unmodifiable(sources);
  }

  Uri _requireListUrl(String text, String label) {
    final uri = Uri.tryParse(text);
    if (uri == null || !isSafeResolverListUrl(uri)) {
      throw FormatException(
        '$label entry `$text` must be a public https:// address without '
        'credentials or a fragment.',
      );
    }
    return uri;
  }

  /// Expands one literal resolver token.
  ///
  /// Returns `null` when the token cannot be parsed and an empty list when a
  /// CIDR is syntactically valid but expands past [stormDnsMaxResolverHosts].
  List<StormDnsResolverEntry>? expandLiteral(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    // A bare address (including a bare CIDR) keeps the default port.
    final bare = _parseTarget(trimmed);
    if (bare != null) {
      return _expandTarget(bare, stormDnsDefaultResolverPort);
    }

    final split = _splitHostPort(trimmed);
    if (split == null) return null;
    final port = int.tryParse(split.port);
    if (port == null || port < 1 || port > 65535) return null;
    final target = _parseTarget(split.host);
    if (target == null) return null;
    return _expandTarget(target, port);
  }

  _ResolverTarget? _parseTarget(String text) {
    if (text.contains('/')) {
      final prefix = _parsePrefix(text);
      return prefix == null ? null : _ResolverTarget.prefix(prefix);
    }
    final address = _parseAddress(text);
    return address == null ? null : _ResolverTarget.address(address);
  }

  List<StormDnsResolverEntry>? _expandTarget(_ResolverTarget target, int port) {
    if (target.address case final address?) {
      return [StormDnsResolverEntry(ip: _formatAddress(address), port: port)];
    }
    final prefix = target.prefixValue!;
    final range = _hostRange(prefix);
    final count = _expansionSize(prefix);
    if (count == null || count > stormDnsMaxResolverHosts) {
      return const [];
    }
    final entries = <StormDnsResolverEntry>[];
    var current = range.first;
    while (true) {
      entries.add(
        StormDnsResolverEntry(ip: _formatAddress(current), port: port),
      );
      if (_compare(current, range.last) >= 0) break;
      current = _next(current);
    }
    return entries;
  }

  /// Number of addresses `appendPrefixResolvers` would emit upstream.
  ///
  /// Upstream gates on `usableHostCount`, which disagrees with the range it
  /// then iterates for very short IPv4 prefixes (a `/1` reports 2 usable hosts
  /// but iterates 2^31-2 addresses). Counting the real range keeps the
  /// documented 65536-address ceiling meaningful instead of hanging the app.
  int? _expansionSize(_Prefix prefix) {
    final bits = prefix.bits;
    if (prefix.address.length == 4) {
      if (bits == 32) return 1;
      if (bits == 31) return 2;
      final hostBits = 32 - bits;
      if (hostBits >= 31) return null;
      return (1 << hostBits) - 2;
    }
    if (bits == 128) return 1;
    if (bits == 127) return 2;
    final hostBits = 128 - bits;
    // Upstream rejects IPv6 prefixes wider than a /112 outright.
    if (hostBits > 16) return null;
    return (1 << hostBits) - 1;
  }

  ({List<int> first, List<int> last}) _hostRange(_Prefix prefix) {
    final network = prefix.masked();
    final last = _lastAddress(prefix);
    final isV4 = network.length == 4;
    if (isV4 && prefix.bits < 31) {
      return (first: _next(network), last: _previous(last));
    }
    if (!isV4 && prefix.bits < 127) {
      return (first: _next(network), last: last);
    }
    return (first: network, last: last);
  }

  List<int> _lastAddress(_Prefix prefix) {
    final bytes = List<int>.from(prefix.masked());
    var hostBits = bytes.length * 8 - prefix.bits;
    for (var i = bytes.length - 1; i >= 0 && hostBits > 0; i--) {
      if (hostBits >= 8) {
        bytes[i] = 0xFF;
        hostBits -= 8;
        continue;
      }
      bytes[i] |= (1 << hostBits) - 1;
      hostBits = 0;
    }
    return bytes;
  }

  List<int> _next(List<int> address) {
    final bytes = List<int>.from(address);
    for (var i = bytes.length - 1; i >= 0; i--) {
      if (bytes[i] < 0xFF) {
        bytes[i]++;
        break;
      }
      bytes[i] = 0;
    }
    return bytes;
  }

  List<int> _previous(List<int> address) {
    final bytes = List<int>.from(address);
    for (var i = bytes.length - 1; i >= 0; i--) {
      if (bytes[i] > 0) {
        bytes[i]--;
        break;
      }
      bytes[i] = 0xFF;
    }
    return bytes;
  }

  int _compare(List<int> left, List<int> right) {
    for (var i = 0; i < left.length; i++) {
      final diff = left[i] - right[i];
      if (diff != 0) return diff;
    }
    return 0;
  }

  _Prefix? _parsePrefix(String text) {
    final slash = text.lastIndexOf('/');
    if (slash <= 0 || slash == text.length - 1) return null;
    final address = _parseAddress(text.substring(0, slash));
    if (address == null) return null;
    final bits = int.tryParse(text.substring(slash + 1));
    if (bits == null || bits < 0 || bits > address.length * 8) return null;
    return _Prefix(address: address, bits: bits);
  }

  List<int>? _parseAddress(String text) {
    if (text.contains(':')) return _parseIpv6(text);
    return _parseIpv4(text);
  }

  List<int>? _parseIpv4(String text) {
    final parts = text.split('.');
    if (parts.length != 4) return null;
    final bytes = <int>[];
    for (final part in parts) {
      if (part.isEmpty || part.length > 3) return null;
      if (part.length > 1 && part.startsWith('0')) return null;
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return null;
      bytes.add(value);
    }
    return bytes;
  }

  List<int>? _parseIpv6(String text) {
    if (text.isEmpty || text.contains('%')) return null;
    final doubleColon = text.indexOf('::');
    if (doubleColon != text.lastIndexOf('::')) return null;

    List<int>? groupsToBytes(
      List<String> groups, {
      required bool allowTrailingIpv4,
    }) {
      final bytes = <int>[];
      for (var index = 0; index < groups.length; index++) {
        final group = groups[index];
        if (group.contains('.')) {
          if (!allowTrailingIpv4 || index != groups.length - 1) return null;
          final embedded = _parseIpv4(group);
          if (embedded == null) return null;
          bytes.addAll(embedded);
          continue;
        }
        if (group.isEmpty || group.length > 4) return null;
        final value = int.tryParse(group, radix: 16);
        if (value == null || value < 0 || value > 0xFFFF) return null;
        bytes
          ..add((value >> 8) & 0xFF)
          ..add(value & 0xFF);
      }
      return bytes;
    }

    if (doubleColon < 0) {
      final groups = text.split(':');
      final bytes = groupsToBytes(groups, allowTrailingIpv4: true);
      return bytes != null && bytes.length == 16 ? bytes : null;
    }

    final headText = text.substring(0, doubleColon);
    final tailText = text.substring(doubleColon + 2);
    final head = headText.isEmpty ? <String>[] : headText.split(':');
    final tail = tailText.isEmpty ? <String>[] : tailText.split(':');
    final headBytes = groupsToBytes(head, allowTrailingIpv4: false);
    final tailBytes = groupsToBytes(tail, allowTrailingIpv4: true);
    if (headBytes == null || tailBytes == null) return null;
    final fill = 16 - headBytes.length - tailBytes.length;
    // `::` must compress at least one complete 16-bit group.
    if (fill < 2) return null;
    return [...headBytes, ...List<int>.filled(fill, 0), ...tailBytes];
  }

  String _formatAddress(List<int> bytes) {
    if (bytes.length == 4) return bytes.join('.');
    // StormDNS calls netip.Addr.Unmap() before de-duplication.
    if (bytes.length == 16 &&
        bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 0xFF &&
        bytes[11] == 0xFF) {
      return bytes.sublist(12).join('.');
    }
    final groups = <int>[
      for (var i = 0; i < 16; i += 2) (bytes[i] << 8) | bytes[i + 1],
    ];
    var bestStart = -1;
    var bestLength = 0;
    var runStart = -1;
    for (var i = 0; i <= groups.length; i++) {
      final isZero = i < groups.length && groups[i] == 0;
      if (isZero && runStart < 0) {
        runStart = i;
      } else if (!isZero && runStart >= 0) {
        final length = i - runStart;
        if (length > bestLength) {
          bestLength = length;
          bestStart = runStart;
        }
        runStart = -1;
      }
    }
    if (bestLength < 2) {
      return groups.map((group) => group.toRadixString(16)).join(':');
    }
    final head = groups
        .sublist(0, bestStart)
        .map((group) => group.toRadixString(16))
        .join(':');
    final tail = groups
        .sublist(bestStart + bestLength)
        .map((group) => group.toRadixString(16))
        .join(':');
    return '$head::$tail';
  }

  ({String host, String port})? _splitHostPort(String text) {
    if (text.startsWith('[')) {
      final end = text.indexOf(']');
      if (end < 0) return null;
      final host = text.substring(1, end).trim();
      final remainder = text.substring(end + 1).trim();
      if (!remainder.startsWith(':')) return null;
      final port = remainder.substring(1).trim();
      if (host.isEmpty || port.isEmpty) return null;
      return (host: host, port: port);
    }
    final lastColon = text.lastIndexOf(':');
    if (lastColon <= 0 || lastColon == text.length - 1) return null;
    final host = text.substring(0, lastColon).trim();
    final port = text.substring(lastColon + 1).trim();
    if (host.isEmpty || port.isEmpty) return null;
    return (host: host, port: port);
  }
}

/// Address safety rules for the resolver-list address itself.
///
/// Private addresses are perfectly valid *inside* a list; this only rejects a
/// list URL that would make the app fetch from the local device or network.
bool isSafeResolverListUrl(Uri uri) {
  if (uri.scheme != 'https') return false;
  if (uri.userInfo.isNotEmpty) return false;
  if (uri.hasFragment) return false;
  if (!uri.hasAuthority || uri.host.isEmpty) return false;
  return !isPrivateResolverListHost(uri.host);
}

bool isPrivateResolverListHost(String host) {
  final normalized = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (normalized == 'localhost' || normalized.endsWith('.localhost')) {
    return true;
  }
  final address = InternetAddress.tryParse(
    normalized.startsWith('[') && normalized.endsWith(']')
        ? normalized.substring(1, normalized.length - 1)
        : normalized,
  );
  if (address == null) return false;
  return isPrivateResolverListAddress(address);
}

bool isPrivateResolverListAddress(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
    return true;
  }
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    if (bytes[0] == 10) return true;
    if (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) return true;
    if (bytes[0] == 192 && bytes[1] == 168) return true;
    if (bytes[0] == 169 && bytes[1] == 254) return true;
    if (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127) return true;
    if (bytes[0] == 0 || bytes[0] >= 240) return true;
    return false;
  }
  // IPv4-mapped IPv6 follows the IPv4 rules too.
  if (bytes.length == 16 &&
      bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 0xFF &&
      bytes[11] == 0xFF) {
    return isPrivateResolverListAddress(
      InternetAddress.fromRawAddress(bytes.sublist(12)),
    );
  }
  if (bytes[0] == 0xFC || bytes[0] == 0xFD) return true;
  if (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80) return true;
  return bytes.every((byte) => byte == 0);
}

/// Cached contents of one remote resolver list.
@immutable
class StormDnsRemoteResolverList {
  const StormDnsRemoteResolverList({
    required this.entries,
    required this.fetchedAt,
  });

  final List<StormDnsResolverEntry> entries;
  final DateTime fetchedAt;
}

abstract interface class StormDnsRemoteResolverListStore {
  /// Resolves every [urls] entry, honouring [refresh].
  ///
  /// A URL that cannot be fetched falls back to its last stored copy even when
  /// the refresh window has elapsed; a URL with no stored copy is omitted from
  /// the result so the caller can skip it and continue.
  Future<Map<Uri, StormDnsRemoteResolverList>> resolve(
    List<Uri> urls, {
    required Duration refresh,
  });
}

/// Disk-backed store: one cache file per URL under the runtime directory.
class DefaultStormDnsRemoteResolverListStore
    implements StormDnsRemoteResolverListStore {
  DefaultStormDnsRemoteResolverListStore({
    required this.cacheDirectoryPath,
    this.parser = const StormDnsResolverSourceParser(),
    Future<String?> Function(Uri url)? download,
    DateTime Function()? now,
  })  : download = download ?? _downloadResolverList,
        now = now ?? DateTime.now;

  final String cacheDirectoryPath;
  final StormDnsResolverSourceParser parser;
  final Future<String?> Function(Uri url) download;
  final DateTime Function() now;

  @override
  Future<Map<Uri, StormDnsRemoteResolverList>> resolve(
    List<Uri> urls, {
    required Duration refresh,
  }) async {
    final result = <Uri, StormDnsRemoteResolverList>{};
    for (final url in urls) {
      if (result.containsKey(url)) continue;
      final cached = await _readCache(url);
      final isFresh =
          cached != null && now().difference(cached.fetchedAt) < refresh;
      if (isFresh) {
        result[url] = cached;
        continue;
      }

      String? body;
      try {
        body = await download(url);
      } catch (_) {
        body = null;
      }
      if (body == null) {
        // Unreachable list: keep serving the last stored copy even when stale.
        if (cached != null) result[url] = cached;
        continue;
      }
      final entries = parseResolverListBody(body, parser: parser);
      final fetched = StormDnsRemoteResolverList(
        entries: entries,
        fetchedAt: now(),
      );
      await _writeCache(url, body, fetched.fetchedAt);
      result[url] = fetched;
    }
    return result;
  }

  File _cacheFile(Uri url) {
    final key = sha256.convert(utf8.encode(url.toString())).toString();
    return File('$cacheDirectoryPath${Platform.pathSeparator}$key.json');
  }

  Future<StormDnsRemoteResolverList?> _readCache(Uri url) async {
    final file = _cacheFile(url);
    if (!file.existsSync()) return null;
    try {
      final value = json.decode(await file.readAsString());
      if (value is! Map) return null;
      final fetchedAt = DateTime.tryParse('${value['fetchedAt']}');
      final body = value['body'];
      if (fetchedAt == null || body is! String) return null;
      return StormDnsRemoteResolverList(
        entries: parseResolverListBody(body, parser: parser),
        fetchedAt: fetchedAt,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(Uri url, String body, DateTime fetchedAt) async {
    try {
      await Directory(cacheDirectoryPath).create(recursive: true);
      await _cacheFile(url).writeAsString(
        json.encode(<String, dynamic>{
          'url': url.toString(),
          'fetchedAt': fetchedAt.toIso8601String(),
          'body': body,
        }),
        flush: true,
      );
    } catch (_) {
      // A cache write failure must not fail the profile; the list was fetched.
    }
  }
}

/// Parses a fetched resolver list. Invalid lines are skipped, matching how
/// StormDNS reads `client_resolvers.txt`.
List<StormDnsResolverEntry> parseResolverListBody(
  String body, {
  StormDnsResolverSourceParser parser = const StormDnsResolverSourceParser(),
}) {
  final entries = <StormDnsResolverEntry>[];
  for (final rawLine in const LineSplitter().convert(body)) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final expanded = parser.expandLiteral(line);
    if (expanded == null || expanded.isEmpty) continue;
    entries.addAll(expanded);
    if (entries.length > stormDnsMaxResolverHosts) {
      return entries.sublist(0, stormDnsMaxResolverHosts);
    }
  }
  return entries;
}

Future<String?> _downloadResolverList(Uri url) async {
  final client = HttpClient()
    ..connectionTimeout = stormDnsRemoteListTimeout
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = _connectPublicResolverListSocket;
  try {
    final request = await client.getUrl(url).timeout(stormDnsRemoteListTimeout);
    request.followRedirects = false;
    final response = await request.close().timeout(stormDnsRemoteListTimeout);
    if (response.statusCode != HttpStatus.ok) {
      // Redirects are not followed: a redirect target is not what the profile
      // author reviewed, and it can point back at the local network.
      return null;
    }
    if (response.contentLength > stormDnsRemoteListMaxBytes) return null;

    final buffer = <int>[];
    await for (final chunk in response.timeout(stormDnsRemoteListTimeout)) {
      buffer.addAll(chunk);
      if (buffer.length > stormDnsRemoteListMaxBytes) return null;
    }
    return utf8.decode(buffer, allowMalformed: true);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<ConnectionTask<Socket>> _connectPublicResolverListSocket(
  Uri url,
  String? proxyHost,
  int? proxyPort,
) async {
  if (proxyHost != null || proxyPort != null) {
    throw const SocketException(
      'Proxy connections are not allowed for resolver lists.',
    );
  }

  var cancelled = false;
  ConnectionTask<Socket>? currentTask;
  Socket? connectedSocket;
  final socket = () async {
    final addresses = await InternetAddress.lookup(url.host)
        .timeout(stormDnsRemoteListTimeout);
    final publicAddresses = addresses
        .where((address) => !isPrivateResolverListAddress(address))
        .toList(growable: false);
    if (publicAddresses.isEmpty) {
      throw SocketException(
        'Resolver-list host `${url.host}` has no public address.',
      );
    }

    Object? lastError;
    for (final address in publicAddresses) {
      if (cancelled) {
        throw const SocketException('Resolver-list connection was cancelled.');
      }
      try {
        currentTask = await Socket.startConnect(address, url.port);
        final candidate =
            await currentTask!.socket.timeout(stormDnsRemoteListTimeout);
        connectedSocket = candidate;
        if (cancelled) {
          candidate.destroy();
          throw const SocketException(
            'Resolver-list connection was cancelled.',
          );
        }
        final secure = await SecureSocket.secure(
          candidate,
          host: url.host,
          supportedProtocols: const ['http/1.1'],
        ).timeout(stormDnsRemoteListTimeout);
        connectedSocket = secure;
        return secure;
      } catch (error) {
        currentTask?.cancel();
        connectedSocket?.destroy();
        connectedSocket = null;
        lastError = error;
      }
    }
    throw SocketException(
      'Could not connect to public resolver-list host `${url.host}`: '
      '$lastError',
    );
  }();

  return ConnectionTask.fromSocket<Socket>(socket, () {
    cancelled = true;
    currentTask?.cancel();
    connectedSocket?.destroy();
  });
}

/// Flattens ordered sources into resolver-file lines.
///
/// De-duplication is by IP with the first occurrence winning, exactly like
/// upstream `addResolver`. The system placeholder is emitted in place so the
/// platform can expand it later without changing the order.
///
/// The whole file is capped at [stormDnsMaxResolverHosts] addresses, not just
/// each source: the MTU scan is linear in the resolver count, so a profile with
/// a dozen CIDRs would otherwise stage a list that takes minutes to work
/// through. Overflow **truncates** rather than failing the profile, for two
/// reasons. A total can be pushed over the limit by a fetched list whose
/// contents the profile author does not control, and refusing to apply a
/// profile because a third-party file grew is worse than serving its first
/// 65536 entries — which is also exactly what [parseResolverListBody] already
/// does to a single oversized list. Note the asymmetry with a single
/// oversized CIDR: that one *is* a profile error, because it is declared
/// literally and the author can fix it.
List<String> buildResolverFileLines({
  required List<StormDnsResolverSource> sources,
  required Map<Uri, StormDnsRemoteResolverList> remoteLists,
}) {
  // The marker costs one line here but expands into the physical network's
  // resolvers on the platform side, so its share of the ceiling is held back.
  final limit =
      sources.any((source) => source is StormDnsSystemResolverSource)
          ? stormDnsMaxResolverHosts - stormDnsSystemDnsReservedHosts
          : stormDnsMaxResolverHosts;
  final lines = <String>[];
  final seen = <String>{};
  var addresses = 0;

  bool addEntry(StormDnsResolverEntry entry) {
    if (addresses >= limit) return false;
    if (seen.add(entry.ip)) {
      lines.add(entry.line);
      addresses += 1;
    }
    return true;
  }

  for (final source in sources) {
    switch (source) {
      case StormDnsSystemResolverSource():
        if (!lines.contains(stormDnsSystemDnsPlaceholder)) {
          lines.add(stormDnsSystemDnsPlaceholder);
        }
      case StormDnsLiteralResolverSource(:final entries):
        for (final entry in entries) {
          if (!addEntry(entry)) break;
        }
      case StormDnsRemoteResolverSource(:final url):
        final list = remoteLists[url];
        if (list == null) continue;
        for (final entry in list.entries) {
          if (!addEntry(entry)) break;
        }
    }
  }
  return lines;
}
