import 'dart:async';
import 'dart:math' as math;

import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/views/profiles/add_profile.dart';
import 'package:flclashx/widgets/text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:flutter_svg/flutter_svg.dart';

class HeroConnect extends ConsumerStatefulWidget {
  const HeroConnect({super.key});

  @override
  ConsumerState<HeroConnect> createState() => _HeroConnectState();
}

class _HeroConnectState extends ConsumerState<HeroConnect>
    with SingleTickerProviderStateMixin {
  late AnimationController _toggleController;
  late Animation<double> _toggleAnimation;
  bool _isStart = false;
  bool _showSpeed = false;
  Timer? _speedTimer;

  @override
  void initState() {
    super.initState();
    _isStart = globalState.appState.runTime != null;
    _showSpeed = _isStart;

    _toggleController = AnimationController(
      vsync: this,
      value: _isStart ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 800),
    );
    _toggleAnimation = CurvedAnimation(
      parent: _toggleController,
      curve: Curves.easeOutBack,
    );

    ref.listenManual(
      runTimeProvider.select((state) => state != null),
      (prev, next) {
        if (next != _isStart) {
          _isStart = next;
          if (_isStart) {
            _toggleController.forward();
            _speedTimer?.cancel();
            _speedTimer = Timer(const Duration(seconds: 1), () {
              if (mounted) setState(() => _showSpeed = true);
            });
          } else {
            _toggleController.reverse();
            _speedTimer?.cancel();
            setState(() => _showSpeed = false);
          }
        }
      },
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _speedTimer?.cancel();
    _toggleController.dispose();
    super.dispose();
  }

  void _handleTap() {
    globalState.appController.updateStatus(!_isStart);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(startButtonSelectorStateProvider);
    final colorScheme = Theme.of(context).colorScheme;

    if (!state.hasProfile) {
      return _buildEmptyCard(context, colorScheme);
    }

    final isReady = state.isInit;
    final traffics = ref.watch(trafficsProvider).list;
    final lastTraffic = traffics.isNotEmpty ? traffics.last : null;

    final groups = ref.watch(currentGroupsStateProvider).value;
    String serverName = '';
    for (final g in groups) {
      final now = g.realNow;
      if (now.isNotEmpty && now != 'DIRECT' && now != 'REJECT') {
        serverName = now;
        break;
      }
    }

    final profile = ref.watch(currentProfileProvider);
    final headers = profile?.providerHeaders ?? {};
    final serviceName = _decodeBase64(headers['flclashx-servicename']);
    final logoUrl = _decodeBase64(headers['flclashx-servicelogo']);
    final announceText = _decodeAnnounce(headers['announce']);
    final mode = ref.watch(patchClashConfigProvider.select((s) => s.mode));
    final globalModeEnabled = ref.watch(globalModeEnabledProvider);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeOutBack,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.7),
          width: 1.5,
        ),
        color: _isStart
            ? Color.lerp(colorScheme.surfaceContainerHigh, colorScheme.primaryContainer, 0.15)!.withValues(alpha: 0.75)
            : colorScheme.surfaceContainerHigh.withValues(alpha: 0.85),
      ),
      child: Column(
        children: [
          // Announce banner
          if (announceText != null && announceText.isNotEmpty) ...[
            _AnnounceBanner(text: announceText),
            const SizedBox(height: 12),
          ],
          // Service badge full width
          if (serviceName != null && serviceName.isNotEmpty)
            _ServiceBadge(name: serviceName, logoUrl: logoUrl),
          const SizedBox(height: 16),
          // Connect ring center, update left, support right
          SizedBox(
            width: double.infinity,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedBuilder(
                  animation: _toggleAnimation,
                  builder: (_, __) => _ConnectRing(
                    progress: _toggleAnimation.value,
                    isStart: _isStart,
                    showSpeed: _showSpeed,
                    isReady: isReady,
                    onTap: isReady ? _handleTap : null,
                    colorScheme: colorScheme,
                    lastTraffic: lastTraffic,
                  ),
                ),
                if (profile != null && profile.type == ProfileType.url) ...[
                  Positioned(
                    left: 0,
                    child: _IconBtn(
                      icon: Icons.refresh_rounded,
                      isLoading: profile.isUpdating,
                      color: colorScheme.onSecondaryContainer,
                      bgColor: colorScheme.secondaryContainer.withValues(alpha: 0.8),
                      onTap: profile.isUpdating
                          ? null
                          : () => globalState.appController.updateProfile(profile),
                    ),
                  ),
                ],
                if (headers['support-url'] != null && headers['support-url']!.isNotEmpty)
                  Positioned(
                    right: 0,
                    child: _IconBtn(
                      icon: Icons.contact_support,
                      color: colorScheme.onSecondaryContainer,
                      bgColor: colorScheme.secondaryContainer.withValues(alpha: 0.8),
                      onTap: () => globalState.openUrl(headers['support-url']!),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // Bottom row: mode | location | nav/settings
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (globalModeEnabled)
                _ModeButton(mode: mode, colorScheme: colorScheme)
              else
                const SizedBox(width: 38),
              if (serverName.isNotEmpty)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: GestureDetector(
                      onTap: () => globalState.appController.toPage(PageLabel.proxies),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                          border: Border.all(
                            color: colorScheme.outlineVariant.withValues(alpha: 0.7),
                            width: 1.5,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Flexible(
                              child: EmojiText(
                                serverName,
                                style: context.textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w500,
                                  color: colorScheme.onSurface,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.swap_horiz_rounded,
                              size: 16,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
              else
                const Spacer(),
              _NavMenuButton(colorScheme: colorScheme),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyCard(BuildContext context, ColorScheme colorScheme) {
    final mode = ref.watch(patchClashConfigProvider.select((s) => s.mode));
    final globalModeEnabled = ref.watch(globalModeEnabledProvider);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.7),
          width: 1.5,
        ),
        color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.85),
      ),
      child: Column(
        children: [
          GestureDetector(
            onTap: () async {
              final url = await globalState.showCommonDialog<String>(
                child: const URLFormDialog(),
              );
              if (url != null) {
                globalState.appController.addProfileFormURL(url);
              }
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.7),
                  width: 1.5,
                ),
                color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_rounded, size: 20, color: colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Text(
                    appLocalizations.addProfile,
                    style: context.textTheme.labelLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (globalModeEnabled)
                _ModeButton(mode: mode, colorScheme: colorScheme)
              else
                const SizedBox(width: 38),
              const Spacer(),
              _NavMenuButton(colorScheme: colorScheme),
            ],
          ),
        ],
      ),
    );
  }
}

class _ConnectRing extends StatelessWidget {
  const _ConnectRing({
    required this.progress,
    required this.isStart,
    required this.showSpeed,
    required this.isReady,
    required this.onTap,
    required this.colorScheme,
    this.lastTraffic,
  });

  final double progress;
  final bool isStart;
  final bool showSpeed;
  final bool isReady;
  final VoidCallback? onTap;
  final ColorScheme colorScheme;
  final Traffic? lastTraffic;

  @override
  Widget build(BuildContext context) {
    final disabledColor = colorScheme.onSurface.withValues(alpha: 0.12);
    final activeColor = Colors.green.shade500;
    final inactiveColor = colorScheme.surfaceContainerHighest;
    final ringColor = isReady
        ? Color.lerp(inactiveColor, activeColor, progress)!
        : disabledColor;
    final iconColor = isReady
        ? Color.lerp(colorScheme.onSurfaceVariant, activeColor, progress)!
        : colorScheme.onSurface.withValues(alpha: 0.38);
    final bgColor = isReady
        ? colorScheme.surfaceContainerLow
        : colorScheme.surfaceContainerHighest.withValues(alpha: 0.6);
    const size = 140.0;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _RingPainter(
            progress: isReady ? progress : 0,
            color: ringColor,
            bgColor: bgColor,
          ),
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: !isReady
                  ? Icon(
                      Icons.power_settings_new_rounded,
                      key: const ValueKey('disabled'),
                      size: 48,
                      color: iconColor,
                    )
                  : showSpeed && lastTraffic != null
                      ? Column(
                          key: const ValueKey('speed'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${lastTraffic!.up}',
                              style: context.textTheme.bodySmall?.copyWith(
                                color: activeColor,
                                fontFamily: FontFamily.jetBrainsMono.value,
                              ),
                            ),
                            Icon(Icons.swap_vert_rounded, size: 16, color: activeColor.withValues(alpha: 0.5)),
                            Text(
                              '${lastTraffic!.down}',
                              style: context.textTheme.bodySmall?.copyWith(
                                color: activeColor,
                                fontFamily: FontFamily.jetBrainsMono.value,
                              ),
                            ),
                          ],
                        )
                      : Icon(
                          Icons.power_settings_new_rounded,
                          key: const ValueKey('power'),
                          size: 48,
                          color: iconColor,
                        ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.bgColor,
  });

  final double progress;
  final Color color;
  final Color bgColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 6;
    const strokeWidth = 5.0;

    // Background ring
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = bgColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );

    // Active ring
    if (progress > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round,
      );
    }

    // Inner fill
    canvas.drawCircle(
      center,
      radius - strokeWidth - 4,
      Paint()..color = bgColor.withValues(alpha: 0.7),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color;
}


class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.color,
    required this.bgColor,
    this.onTap,
    this.isLoading = false,
  });

  final IconData icon;
  final Color color;
  final Color bgColor;
  final VoidCallback? onTap;
  final bool isLoading;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(shape: BoxShape.circle, color: bgColor),
          child: Center(
            child: isLoading
                ? SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: color),
                  )
                : Icon(icon, size: 20, color: color),
          ),
        ),
      );
}

class _NavMenuButton extends StatelessWidget {
  const _NavMenuButton({required this.colorScheme});

  final ColorScheme colorScheme;

  static const _pages = [
    (PageLabel.profiles, Icons.folder_rounded),
    (PageLabel.tools, Icons.settings_rounded),
  ];

  void _show(BuildContext context) {
    final button = context.findRenderObject()! as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset(0, button.size.height), ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    showMenu<PageLabel>(
      context: context,
      position: position,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: _pages.map((p) => PopupMenuItem(
        value: p.$1,
        child: Row(
          children: [
            Icon(p.$2, size: 18, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(Intl.message(p.$1.name)),
          ],
        ),
      )).toList(),
    ).then((value) {
      if (value != null) globalState.appController.toPage(value);
    });
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => _show(context),
    child: Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colorScheme.secondaryContainer.withValues(alpha: 0.8),
      ),
      child: Center(
        child: Icon(Icons.settings_rounded, size: 20, color: colorScheme.onSecondaryContainer),
      ),
    ),
  );
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({required this.mode, required this.colorScheme});

  final Mode mode;
  final ColorScheme colorScheme;

  static IconData _modeIcon(Mode m) => switch (m) {
    Mode.rule => Icons.rule_rounded,
    Mode.global => Icons.public_rounded,
    Mode.direct => Icons.arrow_forward_rounded,
  };

  static const _modes = [Mode.rule, Mode.global];

  static String _modeName(Mode m) => switch (m) {
    Mode.rule => Intl.message('rule'),
    Mode.global => Intl.message('global'),
    Mode.direct => Intl.message('direct'),
  };

  void _showMenu(BuildContext context) {
    final RenderBox button = context.findRenderObject()! as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset(0, button.size.height), ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    showMenu<Mode>(
      context: context,
      position: position,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: _modes.map((m) => PopupMenuItem(
        value: m,
        child: Row(
          children: [
            Icon(
              _modeIcon(m),
              size: 18,
              color: m == mode ? colorScheme.primary : colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text(
              _modeName(m),
              style: TextStyle(
                fontWeight: m == mode ? FontWeight.w600 : FontWeight.w400,
                color: m == mode ? colorScheme.primary : null,
              ),
            ),
          ],
        ),
      )).toList(),
    ).then((value) {
      if (value != null) globalState.appController.changeMode(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showMenu(context),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colorScheme.secondaryContainer.withValues(alpha: 0.8),
        ),
        child: Center(
          child: Icon(_modeIcon(mode), size: 20, color: colorScheme.onSecondaryContainer),
        ),
      ),
    );
  }
}

class _AnnounceBanner extends StatelessWidget {
  const _AnnounceBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: colorScheme.secondaryContainer,
      ),
      child: Text(
        text,
        style: context.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSecondaryContainer,
          height: 1.4,
        ),
      ),
    );
  }
}

String? _decodeAnnounce(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final decoded = _decodeBase64(trimmed);
  if (decoded == null || decoded.trim().isEmpty) return null;
  return decoded.trim();
}

String? _decodeBase64(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  var text = value.trim();
  if (text.startsWith('base64:')) text = text.substring(7).trim();
  if (text.isEmpty) return null;
  try {
    final normalized = base64.normalize(text);
    final decoded = utf8.decode(base64.decode(normalized)).trim();
    return decoded.isEmpty ? null : decoded;
  } catch (_) {
    return value.trim().isEmpty ? null : value.trim();
  }
}

class _ServiceBadge extends StatelessWidget {
  const _ServiceBadge({required this.name, this.logoUrl});

  final String name;
  final String? logoUrl;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    const logoSize = 24.0;

    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: colorScheme.secondaryContainer,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (logoUrl != null && logoUrl!.isNotEmpty) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: logoUrl!.toLowerCase().endsWith('.svg')
                  ? SvgPicture.network(logoUrl!, width: logoSize, height: logoSize)
                  : CachedNetworkImage(
                      imageUrl: logoUrl!,
                      width: logoSize,
                      height: logoSize,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => const SizedBox.shrink(),
                    ),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              name,
              style: context.textTheme.labelMedium?.copyWith(
                color: colorScheme.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _SpeedLabel extends StatelessWidget {
  const _SpeedLabel({
    required this.icon,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: context.textTheme.bodySmall?.copyWith(
              color: color,
              fontFamily: FontFamily.jetBrainsMono.value,
            ),
          ),
          const SizedBox(width: 4),
          Icon(icon, size: 14, color: color),
        ],
      );
}
