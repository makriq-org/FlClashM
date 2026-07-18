import 'dart:io';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/common/process_icon.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/plugins/app.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';

enum ConnectionRowMode { active, log }

/// Fixed row height so the Active list and the Log's CacheItemExtentListView can
/// both use a constant extent — cheap virtualization, no per-item text measuring.
const double kConnRowExtent = 76;

// App icons are stable per process; cache the load future so the 2s connections
// re-poll doesn't recreate it on every rebuild — recreating reset the FutureBuilder
// to its loading state, which is what made rows show the generic icon instead of
// the app's.
final Map<String, Future<ImageProvider?>?> _packageIconCache = {};

Future<ImageProvider?>? _packageIconFuture(String process) =>
    _packageIconCache.putIfAbsent(process, () => app?.getPackageIcon(process));

// Short English connection age: now / 12s / 3m / 2h / 1d.
String _shortAge(DateTime start) {
  final s = DateTime.now().difference(start).inSeconds;
  if (s < 5) return 'now';
  if (s < 60) return '${s}s';
  final m = s ~/ 60;
  if (m < 60) return '${m}m';
  final h = m ~/ 60;
  if (h < 24) return '${h}h';
  return '${h ~/ 24}d';
}

/// One connection rendered as a dense, fixed-height 2-line row: the originating
/// app's icon (with the destination country flag as a corner badge), host:port +
/// down traffic on line 1, a row of badges (process · age · exit node) + up traffic
/// on line 2, and (Active only) a disconnect button.
class ConnectionRow extends StatelessWidget {
  const ConnectionRow({
    super.key,
    required this.connection,
    this.mode = ConnectionRowMode.active,
    this.onClickKeyword,
    this.onBlock,
  });

  final Connection connection;
  final ConnectionRowMode mode;
  final Function(String)? onClickKeyword;
  final VoidCallback? onBlock;

  @override
  Widget build(BuildContext context) {
    final m = connection.metadata;
    final colorScheme = context.colorScheme;
    final host = m.host.isNotEmpty ? m.host : m.destinationIP;
    final hostLine =
        m.destinationPort.isNotEmpty ? '$host:${m.destinationPort}' : host;
    final down = TrafficValue(value: connection.download?.toInt()).show;
    final up = TrafficValue(value: connection.upload?.toInt()).show;

    return InkWell(
      onTap: () {},
      child: SizedBox(
        height: kConnRowExtent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              _leading(context),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: EmojiText(
                            hostLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        _traffic(context, Icons.south_rounded, down),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(child: _badges(context)),
                        const SizedBox(width: 10),
                        _traffic(context, Icons.north_rounded, up),
                      ],
                    ),
                  ],
                ),
              ),
              if (mode == ConnectionRowMode.active && onBlock != null) ...[
                const SizedBox(width: 10),
                IconButton(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(),
                  iconSize: 24,
                  color: colorScheme.onSurfaceVariant,
                  icon: const Icon(Icons.link_off_rounded),
                  onPressed: onBlock,
                ),
                const SizedBox(width: 4),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // App icon (or generic icon) with the destination country flag as a small corner
  // badge. The badge renders only when a country is actually known.
  Widget _leading(BuildContext context) => SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            _icon(context),
            Positioned(
              right: -2,
              bottom: -2,
              child: ConnectionFlag(
                connection: connection,
                size: 20,
                badge: true,
              ),
            ),
          ],
        ),
      );

  // The originating app's icon (rounded square, tappable to filter by process).
  // Falls back to a generic icon when the connection has no app process (system
  // traffic), the platform exposes none (desktop), or the icon can't be loaded.
  Widget _icon(BuildContext context) {
    final process = connection.metadata.process;
    Future<ImageProvider?>? future;
    if (Platform.isAndroid && process.isNotEmpty) {
      future = _packageIconFuture(process);
    } else if (Platform.isWindows) {
      future = windowsProcessIcon(connection.id);
    } else if (Platform.isLinux) {
      future = linuxProcessIcon(connection.id, process);
    }
    if (future == null) return _genericIcon(context);
    return FutureBuilder<ImageProvider?>(
      future: future,
      builder: (_, snapshot) {
        // Neutral placeholder while the icon loads (cached) — never the globe, so
        // app rows don't flash the generic icon.
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _square(context, child: const SizedBox.shrink());
        }
        final icon = snapshot.data;
        if (icon == null) return _genericIcon(context);
        return GestureDetector(
          onTap: process.isEmpty ? null : () => onClickKeyword?.call(process),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image(
              image: icon,
              width: 40,
              height: 40,
              gaplessPlayback: true,
            ),
          ),
        );
      },
    );
  }

  Widget _genericIcon(BuildContext context) => _square(
        context,
        child: Icon(
          Icons.public_rounded,
          size: 22,
          color: context.colorScheme.onSurfaceVariant,
        ),
      );

  Widget _square(BuildContext context, {required Widget child}) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: context.colorScheme.surfaceContainerHighest,
        ),
        alignment: Alignment.center,
        child: child,
      );

  Widget _traffic(BuildContext context, IconData icon, String value) {
    final c = context.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: c),
        const SizedBox(width: 2),
        Text(
          value,
          style: context.textTheme.bodyMedium?.copyWith(color: c),
        ),
      ],
    );
  }

  // Bottom line: process · age · exit node, each as a small badge.
  Widget _badges(BuildContext context) {
    final style = context.textTheme.bodySmall?.copyWith(
      color: context.colorScheme.onSurfaceVariant,
    );
    final process = connection.metadata.process;
    final exit = connection.chains.isNotEmpty ? connection.chains.last : '';
    return Row(
      children: [
        if (process.isNotEmpty) ...[
          Flexible(
            child: _badge(
              context,
              Text(
                process,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
              onTap: () => onClickKeyword?.call(process),
            ),
          ),
          const SizedBox(width: 5),
        ],
        _badge(context, Text(_shortAge(connection.start), style: style)),
        if (exit.isNotEmpty) ...[
          const SizedBox(width: 5),
          Flexible(
            child: _badge(
              context,
              EmojiText(
                exit,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
              onTap: () => onClickKeyword?.call(exit),
            ),
          ),
        ],
      ],
    );
  }

  Widget _badge(BuildContext context, Widget child, {VoidCallback? onTap}) {
    final box = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(7),
      ),
      child: child,
    );
    if (onTap == null) return box;
    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: onTap,
      child: box,
    );
  }
}
