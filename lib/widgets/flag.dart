import 'dart:async';

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
final Map<String, String> _ipCountryCache = {};
// Serialize geoip lookups so a single list build can't flood the core IPC channel
// with a burst of requests (which would compete with the connections/traffic polls).
Future<void> _geoipQueue = Future.value();

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
    final cached = _ipCountryCache[ip];
    if (cached != null) {
      _set(cached);
      return;
    }
    final completer = Completer<String>();
    _geoipQueue = _geoipQueue.then((_) async {
      final hit = _ipCountryCache[ip];
      if (hit != null) {
        completer.complete(hit);
        return;
      }
      final info = await clashCore.getCountryCode(ip);
      final cc = info?.countryCode ?? '';
      _ipCountryCache[ip] = cc;
      completer.complete(cc);
    });
    _set(await completer.future);
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
