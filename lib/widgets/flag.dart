import 'dart:async';
import 'dart:collection';

import 'package:flclashx/clash/clash.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/widgets/text.dart';
import 'package:flutter/material.dart';

/// 'NL' -> 🇳🇱 ; anything that isn't a 2-letter code -> 🌐 globe.
String countryCodeToEmoji(String code) {
  if (code.length != 2) return '🌐';
  final upper = code.toUpperCase();
  final first = 0x1F1E6 - 0x41 + upper.codeUnitAt(0);
  final second = 0x1F1E6 - 0x41 + upper.codeUnitAt(1);
  return String.fromCharCodes([first, second]);
}

/// Pull the ISO code out of the first 🇳🇱-style flag emoji in [text]
/// (e.g. "🇳🇱 Amsterdam" -> "NL"); null when there's no flag.
String? flagToCountryCode(String text) {
  final runes = text.runes.toList();
  for (var i = 0; i < runes.length - 1; i++) {
    final a = runes[i];
    final b = runes[i + 1];
    if (a >= 0x1F1E6 && a <= 0x1F1FF && b >= 0x1F1E6 && b <= 0x1F1FF) {
      final c1 = a - 0x1F1E6 + 0x41;
      final c2 = b - 0x1F1E6 + 0x41;
      return String.fromCharCodes([c1, c2]);
    }
  }
  return null;
}

// destIP -> ISO country, cached so the 2s connections re-poll doesn't repeat geoip.
const _maxIpCountryCacheEntries = 512;
final LinkedHashMap<String, String> _ipCountryCache = LinkedHashMap();
final Map<String, Future<String>> _ipCountryInFlight = {};
// Serialize geoip lookups so a single list build can't flood the core IPC channel
// with a burst of requests (which would compete with the connections/traffic polls).
Future<void> _geoipQueue = Future.value();

String? _readCachedCountry(String ip) {
  final value = _ipCountryCache.remove(ip);
  if (value != null) {
    _ipCountryCache[ip] = value;
  }
  return value;
}

void _cacheCountry(String ip, String country) {
  _ipCountryCache.remove(ip);
  _ipCountryCache[ip] = country;
  while (_ipCountryCache.length > _maxIpCountryCacheEntries) {
    _ipCountryCache.remove(_ipCountryCache.keys.first);
  }
}

Future<String> _resolveCountry(String ip) {
  final cached = _readCachedCountry(ip);
  if (cached != null) {
    return Future.value(cached);
  }
  final inFlight = _ipCountryInFlight[ip];
  if (inFlight != null) {
    return inFlight;
  }
  final task = _geoipQueue.catchError((_) {}).then((_) async {
    final queuedHit = _readCachedCountry(ip);
    if (queuedHit != null) {
      return queuedHit;
    }
    final info = await clashCore.getCountryCode(ip);
    final country = info?.countryCode ?? '';
    _cacheCountry(ip, country);
    return country;
  });
  _geoipQueue = task.then<void>(
    (_) {},
    onError: (_, __) {},
  );
  _ipCountryInFlight[ip] = task;
  unawaited(
    task.then<void>(
      (_) => _ipCountryInFlight.remove(ip),
      onError: (_, __) => _ipCountryInFlight.remove(ip),
    ),
  );
  return task;
}

/// The destination host's country, from the core's local geoip on the connection's
/// destination IP. Cached per IP and looked up through a serial queue. In badge mode
/// it renders nothing until/unless a country is resolved (no stray globe).
class ConnectionFlag extends StatefulWidget {
  const ConnectionFlag({
    super.key,
    required this.connection,
    this.size = 28,
    this.badge = false,
  });

  final Connection connection;
  final double size;

  /// Badge mode: a small flag chip on a circular backdrop, for overlaying on an
  /// icon corner. Renders nothing when the country is unknown (no globe).
  final bool badge;

  @override
  State<ConnectionFlag> createState() => _ConnectionFlagState();
}

class _ConnectionFlagState extends State<ConnectionFlag> {
  String _code = '';

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  @override
  void didUpdateWidget(ConnectionFlag oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connection.metadata.destinationIP !=
        widget.connection.metadata.destinationIP) {
      unawaited(_resolve());
    }
  }

  Future<void> _resolve() async {
    final ip = widget.connection.metadata.destinationIP;
    if (ip.isEmpty) {
      _set('');
      return;
    }
    try {
      final code = await _resolveCountry(ip);
      if (widget.connection.metadata.destinationIP == ip) {
        _set(code);
      }
    } catch (_) {
      if (widget.connection.metadata.destinationIP == ip) {
        _set('');
      }
    }
  }

  void _set(String code) {
    if (!mounted || code == _code) return;
    setState(() => _code = code);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.badge) {
      if (_code.length != 2) return const SizedBox.shrink();
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Theme.of(context).colorScheme.surface,
        ),
        alignment: Alignment.center,
        child: EmojiText(
          countryCodeToEmoji(_code),
          style: TextStyle(fontSize: widget.size * 0.72),
        ),
      );
    }
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Center(
        child: EmojiText(
          countryCodeToEmoji(_code),
          style: TextStyle(fontSize: widget.size * 0.82),
        ),
      ),
    );
  }
}
