import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/views/profiles/add_profile.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------
String _countryCodeToEmoji(String code) {
  if (code.length != 2) return '🌐';
  final upper = code.toUpperCase();
  final first = 0x1F1E6 - 0x41 + upper.codeUnitAt(0);
  final second = 0x1F1E6 - 0x41 + upper.codeUnitAt(1);
  return String.fromCharCodes([first, second]);
}

// Derive an ISO country code from the first regional-indicator flag emoji found
// in [text] (e.g. "🇳🇱 Amsterdam" -> "NL"). Returns null when there's no flag.
String? _flagToCountryCode(String text) {
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

// Collect the distinct ISO country codes carried by the flag emoji in the names
// of every proxy in [group], descending a few levels into nested groups. Used to
// paint a faint backdrop of the group's flags behind the active one.
List<String> _collectGroupFlags(List<Group> groups, Group group) {
  final seen = <String>{};
  final codes = <String>[];
  void walk(Group g, int depth) {
    if (depth > 4) return;
    for (final proxy in g.all) {
      final code = _flagToCountryCode(proxy.name);
      if (code != null) {
        if (seen.add(code)) codes.add(code);
      } else {
        final sub = groups.getGroup(proxy.name);
        if (sub != null) walk(sub, depth + 1);
      }
    }
  }

  walk(group, 0);
  return codes;
}

// Strip only the *leading* emoji run from the name — typically the flag prefix
// (e.g. "🇳🇱 Amsterdam"), which we already render separately as the flag icon.
// Emoji that appear later in the name are kept intact.
String _stripLeadingEmoji(String text) {
  bool isEmojiRune(int r) {
    final isFlag = r >= 0x1F1E6 && r <= 0x1F1FF;
    final isModifier =
        r == 0x200D || r == 0xFE0F || (r >= 0x1F3FB && r <= 0x1F3FF);
    final isPictograph = (r >= 0x1F000 && r <= 0x1FAFF) ||
        (r >= 0x2600 && r <= 0x27BF) ||
        (r >= 0x2190 && r <= 0x21FF) ||
        (r >= 0x2B00 && r <= 0x2BFF) ||
        (r >= 0x2300 && r <= 0x23FF);
    return isFlag || isModifier || isPictograph;
  }

  bool isSpace(int r) =>
      r == 0x20 || r == 0x09 || r == 0xA0 || r == 0x0A || r == 0x0D;

  final runes = text.runes.toList();
  var start = 0;
  // Consume the leading run of emoji (and any whitespace around it) so a flag
  // prefixed with or followed by spaces is still removed; stop at the first
  // real character and keep the remainder verbatim.
  while (start < runes.length &&
      (isEmojiRune(runes[start]) || isSpace(runes[start]))) {
    start++;
  }
  return String.fromCharCodes(runes.sublist(start))
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return '${value.toStringAsFixed(1)} ${units[i]}';
}

// Russian-aware plural form for "days" (mirrors MetainfoWidget's declension).
String _daysWord(int days) {
  if (days % 100 >= 11 && days % 100 <= 19) return appLocalizations.days;
  switch (days % 10) {
    case 1:
      return appLocalizations.day;
    case 2:
    case 3:
    case 4:
      return appLocalizations.daysGenitive;
    default:
      return appLocalizations.days;
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

// ----------------------------------------------------------------------------
// Focusable tap wrapper — makes a tappable area reachable by a D-pad/remote
// (Android TV). The hero board's controls were bare GestureDetectors, which
// have no focus node and don't respond to D-pad-center/Enter, so the TV remote
// couldn't focus or activate them. This adds a focus node, a primary-colour ring
// + subtle scale while focused, and activates onTap on both tap and Enter/Select.
// ----------------------------------------------------------------------------
class _FocusableTap extends StatefulWidget {
  const _FocusableTap({
    required this.onTap,
    required this.child,
    this.autofocus = false,
    this.borderRadius = 18,
  });

  final VoidCallback? onTap;
  final Widget child;
  final bool autofocus;
  final double borderRadius;

  @override
  State<_FocusableTap> createState() => _FocusableTapState();
}

class _FocusableTapState extends State<_FocusableTap> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return FocusableActionDetector(
      enabled: enabled,
      autofocus: widget.autofocus && enabled,
      onShowFocusHighlight: (value) {
        if (mounted && value != _focused) setState(() => _focused = value);
      },
      // No explicit Map<Type, Action<Intent>> annotation: `Action` is ambiguous here
      // (flclashx models also export an `Action` class). Context inference from
      // FocusableActionDetector.actions gives the right type without naming it.
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      // Focus ring only — no scale-up. AnimatedScale painted outside the layout
      // bounds, so a full-width autofocused control (the connect button on
      // desktop) spilled past the window edges once 1.5% of its width exceeded
      // the 16px side padding.
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.borderRadius + 4),
          border: Border.all(
            color:
                _focused ? context.colorScheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: widget.child,
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// Hero
// ----------------------------------------------------------------------------
class HeroConnect extends ConsumerWidget {
  const HeroConnect({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(startButtonSelectorStateProvider);
    if (!state.hasProfile) return const _EmptyHero();

    final isReady = state.isInit;
    final profile = ref.watch(currentProfileProvider);
    final headers = profile?.providerHeaders ?? {};
    final serviceName = _decodeBase64(headers['flclashx-servicename']) ?? appName;
    final logoUrl = _decodeBase64(headers['flclashx-servicelogo']);
    final announce = _decodeAnnounce(headers['announce']);
    final sub = profile?.subscriptionInfo;
    // Only show the traffic card when there's something to show — a data limit or an
    // expiry. Unlimited + no expiry => hide it entirely.
    final hasSub = sub != null && (sub.total > 0 || sub.expire > 0);

    // Buy/renew links carried by the profile. The buttons (under the traffic
    // card) only appear when the matching condition is met:
    //   buyplan    -> less than 3 days left (expired included), time-limited plans
    //   buytraffic -> less than 10% of the limit remaining, capped plans
    final buyPlanUrl = headers['flclashx-buyplan'];
    final buyTrafficUrl = headers['flclashx-buytraffic'];
    var showBuyPlan = false;
    var showBuyTraffic = false;
    if (sub != null) {
      if (buyPlanUrl != null && buyPlanUrl.isNotEmpty && sub.expire > 0) {
        showBuyPlan = DateTime.fromMillisecondsSinceEpoch(sub.expire * 1000)
                .difference(DateTime.now()) <
            const Duration(days: 3);
      }
      if (buyTrafficUrl != null && buyTrafficUrl.isNotEmpty && sub.total > 0) {
        final used = sub.upload + sub.download;
        showBuyTraffic = (sub.total - used) < sub.total * 0.1;
      }
    }
    final showBuy = showBuyPlan || showBuyTraffic;

    final groups = ref.watch(currentGroupsStateProvider).value;
    var serverName = '';
    String? testUrl;
    Group? activeGroup;
    // Server label = the current pick of the proxy group named in the
    // `flclashx-serverinfo` header: its selected leaf host (the real location),
    // or the sub-group's own name when the pick is itself a group (see
    // resolveToDisplayName). Fall back to the first group with a live selection.
    final serverInfoHeader = headers['flclashx-serverinfo'];
    if (serverInfoHeader != null && serverInfoHeader.isNotEmpty) {
      final groupName = _decodeBase64(serverInfoHeader) ?? serverInfoHeader.trim();
      final group = groups.getGroup(groupName);
      if (group != null) {
        activeGroup = group;
        serverName = groups.resolveToDisplayName(group.name);
        testUrl = group.testUrl;
      }
    }
    if (serverName.isEmpty) {
      for (final g in groups) {
        final now = g.realNow;
        if (now.isNotEmpty && now != 'DIRECT' && now != 'REJECT') {
          activeGroup = g;
          serverName = groups.resolveToDisplayName(g.name);
          testUrl = g.testUrl;
          break;
        }
      }
    }
    final displayName = _stripLeadingEmoji(serverName);
    final nameCountryCode = _flagToCountryCode(serverName);
    final groupFlagCodes =
        activeGroup != null ? _collectGroupFlags(groups, activeGroup) : const <String>[];
    // Other locations in the group: their distinct flag countries (shown as stacked
    // flags behind the active one) plus a total count (the badge). Falls back to the
    // sibling-proxy count when node names carry no flag emoji.
    final activeUpper = nameCountryCode?.toUpperCase();
    final otherCodes =
        groupFlagCodes.where((c) => c.toUpperCase() != activeUpper).toList();
    final rawOther = otherCodes.isNotEmpty
        ? otherCodes.length
        : (activeGroup != null ? activeGroup.all.length - 1 : 0);
    final otherLocations = rawOther < 0 ? 0 : rawOther;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 8),
                _Logo(logoUrl: logoUrl),
                const SizedBox(height: 16),
                Text(
                  serviceName,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (announce != null && announce.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _AnnounceBanner(text: announce),
                ],
                const SizedBox(height: 18),
                _HeroActionRow(
                  isUpdating: profile?.isUpdating ?? false,
                  onUpdate: profile == null
                      ? null
                      : () => globalState.appController.updateProfile(profile),
                  supportUrl: headers['support-url'],
                ),
                const SizedBox(height: 18),
                if (hasSub) ...[
                  _TrafficCard(sub: sub),
                  const SizedBox(height: 12),
                ],
                if (showBuy) ...[
                  _BuyButtons(
                    showBuyPlan: showBuyPlan,
                    showBuyTraffic: showBuyTraffic,
                    buyPlanUrl: buyPlanUrl,
                    buyTrafficUrl: buyTrafficUrl,
                  ),
                  const SizedBox(height: 12),
                ],
                _ServerPanel(
                  serverName: serverName,
                  displayName: displayName,
                  nameCountryCode: nameCountryCode,
                  testUrl: testUrl,
                  otherCodes: otherCodes,
                  otherLocations: otherLocations,
                ),
              ],
            ),
          ),
        ),
        // Pinned to the bottom of the hero, just above the nav bar.
        const SizedBox(height: 14),
        _ConnectButton(isReady: isReady),
      ],
    );
  }
}

// ----------------------------------------------------------------------------
// Logo
// ----------------------------------------------------------------------------
class _Logo extends StatelessWidget {
  const _Logo({this.logoUrl});

  final String? logoUrl;

  @override
  Widget build(BuildContext context) {
    const size = 104.0;
    final fallback = ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: Image.asset('assets/images/icon.png', width: size, height: size, fit: BoxFit.cover),
    );
    if (logoUrl == null || logoUrl!.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: logoUrl!.toLowerCase().endsWith('.svg')
          ? SvgPicture.network(logoUrl!, width: size, height: size,
              placeholderBuilder: (_) => fallback)
          : CachedNetworkImage(
              imageUrl: logoUrl!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => fallback,
            ),
    );
  }
}

// ----------------------------------------------------------------------------
// Traffic card (usage bar + amount + days left)
// ----------------------------------------------------------------------------
class _TrafficCard extends StatelessWidget {
  const _TrafficCard({required this.sub});

  final SubscriptionInfo sub;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final used = (sub.upload + sub.download).toInt();
    final total = sub.total;
    final unlimited = total <= 0;
    final progress = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final barColor = progress > 0.9
        ? Colors.red.shade400
        : progress > 0.7
            ? Colors.orange.shade400
            : colorScheme.primary;

    int? daysLeft;
    if (sub.expire > 0) {
      daysLeft = DateTime.fromMillisecondsSinceEpoch(sub.expire * 1000)
          .difference(DateTime.now())
          .inDays;
      if (daysLeft < 0) daysLeft = 0;
    }

    final daysUrgent = daysLeft != null && daysLeft <= 3;
    final daysColor = daysUrgent ? Colors.red.shade400 : colorScheme.primary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  unlimited
                      ? _formatBytes(used)
                      : '${_formatBytes(used)} / ${_formatBytes(total)}',
                  style: context.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFamily: FontFamily.jetBrainsMono.value,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (daysLeft != null) ...[
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: daysColor.withValues(alpha: 0.14),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.event_rounded, size: 14, color: daysColor),
                      const SizedBox(width: 5),
                      Text(
                        '${appLocalizations.remaining} $daysLeft ${_daysWord(daysLeft)}',
                        style: context.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: daysColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          if (!unlimited) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                children: [
                  Container(height: 9, color: colorScheme.surfaceContainerHighest),
                  FractionallySizedBox(
                    widthFactor: progress <= 0 ? 0.0 : progress,
                    child: Container(
                      height: 9,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        gradient: LinearGradient(
                          colors: [barColor.withValues(alpha: 0.7), barColor],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// Buy / renew buttons (shown under the traffic card)
// ----------------------------------------------------------------------------
class _BuyButtons extends StatelessWidget {
  const _BuyButtons({
    required this.showBuyPlan,
    required this.showBuyTraffic,
    required this.buyPlanUrl,
    required this.buyTrafficUrl,
  });

  final bool showBuyPlan;
  final bool showBuyTraffic;
  final String? buyPlanUrl;
  final String? buyTrafficUrl;

  @override
  Widget build(BuildContext context) {
    final plan = _HeroBuyButton(
      icon: Icons.autorenew_rounded,
      label: 'Продлить подписку',
      filled: true,
      onTap: () => globalState.openUrl(buyPlanUrl!),
    );
    final traffic = _HeroBuyButton(
      icon: Icons.add_rounded,
      label: 'Докупить трафик',
      filled: false,
      onTap: () => globalState.openUrl(buyTrafficUrl!),
    );

    // Both triggers -> side by side, one each; a single trigger -> full width.
    if (showBuyPlan && showBuyTraffic) {
      return Row(
        children: [
          Expanded(child: plan),
          const SizedBox(width: 10),
          Expanded(child: traffic),
        ],
      );
    }
    if (showBuyPlan) return plan;
    if (showBuyTraffic) return traffic;
    return const SizedBox.shrink();
  }
}

class _HeroBuyButton extends StatelessWidget {
  const _HeroBuyButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final bg = filled
        ? colorScheme.primary
        : colorScheme.surfaceContainerHigh.withValues(alpha: 0.6);
    final fg = filled ? colorScheme.onPrimary : colorScheme.primary;
    return _FocusableTap(
      borderRadius: 16,
      onTap: onTap,
      child: Container(
        width: double.infinity,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: bg,
          border: filled
              ? null
              : Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.titleSmall
                    ?.copyWith(color: fg, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// Server panel (flag / host / ip / ping) — tap to change server
// ----------------------------------------------------------------------------
class _ServerPanel extends ConsumerWidget {
  const _ServerPanel({
    required this.serverName,
    required this.displayName,
    required this.nameCountryCode,
    required this.testUrl,
    this.otherCodes = const [],
    this.otherLocations = 0,
  });

  final String serverName;
  final String displayName;
  final String? nameCountryCode;
  final String? testUrl;
  final List<String> otherCodes;
  final int otherLocations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = context.colorScheme;
    // select(!=null): the hero card only needs the connected/disconnected boolean,
    // so watching the raw runTime rebuilt the entire card (flags, traffic, server
    // panel, buy buttons, announce) every second. The elapsed-time text lives in
    // _ConnectButton, which intentionally keeps watching the value.
    final isConnected =
        ref.watch(runTimeProvider.select((value) => value != null));
    final delay = serverName.isNotEmpty
        ? ref.watch(getDelayProvider(proxyName: serverName, testUrl: testUrl))
        : null;

    return ValueListenableBuilder(
      valueListenable: detectionState.state,
      builder: (_, networkState, __) {
        final ipInfo = networkState.ipInfo;
        // Prefer the flag carried in the server name; fall back to the detected
        // exit-IP country, then a globe.
        final code = nameCountryCode ?? ipInfo?.countryCode ?? '';
        final flag = _countryCodeToEmoji(code);
        final title = displayName.isNotEmpty ? displayName : '—';

        return _FocusableTap(
          borderRadius: 18,
          onTap: () => globalState.appController.toPage(PageLabel.proxies),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
              border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
            ),
            child: Row(
              children: [
                _FlagCircle(
                  countryCode: code,
                  fallbackEmoji: flag,
                  otherCodes: otherCodes,
                  stackCount: otherLocations,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // IP line: hidden while the tunnel is off. Once connected:
                      // the real IP when known; a spinner + "determining IP" while
                      // actively resolving; a muted dash if resolution finished
                      // without an IP (failed / timed out).
                      if (isConnected) ...[
                        const SizedBox(height: 3),
                        if (ipInfo != null)
                          Text(
                            ipInfo.ip,
                            style: context.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              fontFamily: FontFamily.jetBrainsMono.value,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        else if (networkState.isTesting || networkState.isLoading)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.6,
                                  color: colorScheme.primary,
                                ),
                              ),
                              const SizedBox(width: 7),
                              Text(
                                appLocalizations.determiningIp,
                                style: context.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          )
                        else
                          Text(
                            '—',
                            style: context.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              fontFamily: FontFamily.jetBrainsMono.value,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // Fixed width so the bars + ms text stay horizontally centred and
                // don't drift as the delay text width changes.
                SizedBox(
                  width: 46,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _SignalBars(delay: delay),
                      if (delay != null && delay > 0) ...[
                        const SizedBox(height: 3),
                        Text(
                          '$delay ms',
                          textAlign: TextAlign.center,
                          style: context.textTheme.labelSmall?.copyWith(
                            color: utils.getDelayColor(delay) ?? colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                            fontFamily: FontFamily.jetBrainsMono.value,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // Chevron: signals the panel is tappable (drill into the server list).
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// Large circle filled with the country flag (cropped to a circle; falls back to the
// flag emoji / globe). When the group has other locations, a couple of neutral
// theme-coloured discs peek out from behind it as a tidy "stack" affordance.
class _FlagCircle extends StatelessWidget {
  const _FlagCircle({
    required this.countryCode,
    required this.fallbackEmoji,
    this.otherCodes = const [],
    this.stackCount = 0,
  });

  final String countryCode;
  final String fallbackEmoji;
  final List<String> otherCodes;
  final int stackCount;

  @override
  Widget build(BuildContext context) {
    const size = 52.0;
    final colorScheme = context.colorScheme;
    final cc = countryCode.trim().toLowerCase();

    Widget fallback() => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colorScheme.surfaceContainerHighest,
          ),
          alignment: Alignment.center,
          child: EmojiText(fallbackEmoji, style: const TextStyle(fontSize: size * 0.5)),
        );

    final active = cc.length != 2
        ? fallback()
        : ClipOval(
            child: CachedNetworkImage(
              imageUrl: 'https://flagcdn.com/w160/$cc.png',
              width: size,
              height: size,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(
                width: size,
                height: size,
                color: colorScheme.surfaceContainerHighest,
              ),
              errorWidget: (_, __, ___) => fallback(),
            ),
          );

    // Up to two of the group's other-location flags peek straight up from behind the
    // active one — smaller, ringed in the surface colour, and progressively darkened
    // the further back they sit, so they read as a centred stack receding into depth.
    final backs = otherCodes.take(2).toList();
    Widget backFlag(int i, String code) {
      final s = size * (1 - 0.14 * i);
      return Transform.translate(
        offset: Offset(0, -10.0 * i),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: colorScheme.surface, width: 1.5),
          ),
          child: ClipOval(
            child: Stack(
              children: [
                CachedNetworkImage(
                  imageUrl: 'https://flagcdn.com/w80/${code.toLowerCase()}.png',
                  width: s,
                  height: s,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => SizedBox(width: s, height: s),
                  errorWidget: (_, __, ___) => Container(
                    width: s,
                    height: s,
                    color: colorScheme.surfaceContainerHighest,
                  ),
                ),
                // Depth scrim: deeper cards are darker.
                Positioned.fill(
                  child: ColoredBox(color: Colors.black.withValues(alpha: 0.15 * i)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final badge = stackCount <= 0
        ? null
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              color: colorScheme.primary,
              border: Border.all(color: colorScheme.surface, width: 1.5),
            ),
            child: Text(
              '+$stackCount',
              style: context.textTheme.labelSmall?.copyWith(
                color: colorScheme.onPrimary,
                fontWeight: FontWeight.w700,
                fontFamily: FontFamily.jetBrainsMono.value,
              ),
            ),
          );

    // The active flag with its peeking back-flags and corner badge, as one 52px unit.
    final unit = Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        for (var i = backs.length; i >= 1; i--) backFlag(i, backs[i - 1]),
        active,
        if (badge != null) Positioned(right: -3, bottom: -3, child: badge),
      ],
    );

    // Reserve headroom matching how far the deepest back-flag sticks up (plus a little
    // for the badge), so the *whole* construction — not just the active flag — is
    // vertically centred in the row.
    final topPeek = backs.isEmpty
        ? 0.0
        : (10.0 * backs.length + size * (1 - 0.14 * backs.length) / 2 - size / 2 + 2)
            .clamp(0.0, 40.0)
            .toDouble();
    final bottomPeek = badge != null ? 7.0 : 0.0;

    if (topPeek == 0 && bottomPeek == 0) {
      return SizedBox(width: size, height: size, child: unit);
    }
    return SizedBox(
      width: size,
      height: size + topPeek + bottomPeek,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(top: topPeek, left: 0, width: size, height: size, child: unit),
        ],
      ),
    );
  }
}

// Mobile-network-style signal bars representing ping quality.
class _SignalBars extends StatelessWidget {
  const _SignalBars({required this.delay});

  final int? delay;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final dim = colorScheme.onSurfaceVariant.withValues(alpha: 0.25);

    final int level;
    final Color color;
    if (delay == null || delay == 0) {
      level = 0;
      color = dim;
    } else if (delay! < 0) {
      level = 0;
      color = Colors.red.shade400;
    } else {
      color = utils.getDelayColor(delay) ?? Colors.green;
      level = delay! < 150
          ? 4
          : delay! < 300
              ? 3
              : delay! < 600
                  ? 2
                  : 1;
    }

    const heights = [9.0, 13.0, 17.0, 21.0];
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(4, (i) => Padding(
          padding: EdgeInsets.only(left: i == 0 ? 0 : 3),
          child: Container(
            width: 4,
            height: heights[i],
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              color: i < level ? color : dim,
            ),
          ),
        )),
    );
  }
}

// ----------------------------------------------------------------------------
// Connect button — shows the time counter while connected
// ----------------------------------------------------------------------------
class _ConnectButton extends ConsumerWidget {
  const _ConnectButton({required this.isReady});

  final bool isReady;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = context.colorScheme;
    final runTime = ref.watch(runTimeProvider);
    final isStart = runTime != null;

    final Color bg;
    final Color fg;
    if (!isReady) {
      bg = colorScheme.surfaceContainerHighest.withValues(alpha: 0.5);
      fg = colorScheme.onSurface.withValues(alpha: 0.38);
    } else if (isStart) {
      bg = colorScheme.surfaceContainerHigh.withValues(alpha: 0.8);
      fg = colorScheme.primary;
    } else {
      bg = colorScheme.primary;
      fg = colorScheme.onPrimary;
    }

    return _FocusableTap(
      autofocus: true,
      borderRadius: 24,
      onTap: isReady
          ? () {
              if (Platform.isAndroid) {
                HapticFeedback.mediumImpact();
              }
              globalState.appController.updateStatus(!isStart);
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: double.infinity,
        height: 54,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: bg,
          border: isStart
              ? Border.all(color: colorScheme.primary.withValues(alpha: 0.4))
              : null,
        ),
        // Running: uptime only. Stopped: just a Play glyph (no "Start" label).
        child: isStart
            ? Text(
                utils.getTimeText(runTime),
                style: context.textTheme.titleSmall?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  fontFamily: FontFamily.jetBrainsMono.value,
                ),
              )
            : Icon(Icons.play_arrow_rounded, size: 30, color: fg),
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// Empty state (no profile)
// ----------------------------------------------------------------------------
class _EmptyHero extends ConsumerWidget {
  const _EmptyHero();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = context.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        const _Logo(),
        const SizedBox(height: 16),
        Text(
          appName,
          style: context.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 24),
        _FocusableTap(
          autofocus: true,
          borderRadius: 16,
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
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: colorScheme.primary,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add_rounded, size: 20, color: colorScheme.onPrimary),
                const SizedBox(width: 8),
                Text(
                  appLocalizations.addProfile,
                  style: context.textTheme.titleSmall?.copyWith(
                    color: colorScheme.onPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _AnnounceBanner extends StatelessWidget {
  const _AnnounceBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: colorScheme.secondaryContainer,
      ),
      // EmojiText (not Text): renders flag/emoji runs with the Twemoji font so
      // they show up — plain Text drops country flags entirely on Windows.
      child: EmojiText(
        text,
        style: context.textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSecondaryContainer,
          height: 1.4,
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// Hero actions: refresh / support chips
// ----------------------------------------------------------------------------
class _HeroActionRow extends ConsumerWidget {
  const _HeroActionRow({
    required this.isUpdating,
    required this.onUpdate,
    this.supportUrl,
  });

  final bool isUpdating;
  final VoidCallback? onUpdate;
  final String? supportUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSupport = supportUrl != null && supportUrl!.isNotEmpty;
    final globalModeEnabled = ref.watch(globalModeEnabledProvider);
    return Row(
      children: [
        Expanded(
          child: _ActionChip(
            icon: Icons.refresh_rounded,
            label: appLocalizations.update,
            busy: isUpdating,
            onTap: onUpdate,
          ),
        ),
        if (hasSupport) ...[
          const SizedBox(width: 10),
          Expanded(
            child: _ActionChip(
              icon: Icons.support_agent_rounded,
              label: appLocalizations.support,
              onTap: () => globalState.openUrl(supportUrl!),
            ),
          ),
        ],
        if (globalModeEnabled) ...[
          const SizedBox(width: 10),
          const _ModeChip(),
        ],
      ],
    );
  }
}

// Outbound-mode chip (rule/global) — icon-only square in the action-chip visual
// language, pinned after the Support chip. The current mode is conveyed by the
// icon itself; tapping opens the same mode popup as on the proxies page. Only
// rendered when the global-mode setting is on (gated by the caller).
class _ModeChip extends ConsumerWidget {
  const _ModeChip();

  IconData _modeIcon(Mode mode) => switch (mode) {
        Mode.rule => Icons.rule,
        Mode.global => Icons.public,
        Mode.direct => Icons.flash_on,
      };

  String _modeLabel(Mode mode) => switch (mode) {
        Mode.rule => appLocalizations.rule,
        Mode.global => appLocalizations.global,
        Mode.direct => appLocalizations.direct,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = context.colorScheme;
    final mode = ref.watch(
      patchClashConfigProvider.select((state) => state.mode),
    );
    return CommonPopupBox(
      targetBuilder: (open) => Tooltip(
        message: _modeLabel(mode),
        child: _FocusableTap(
          borderRadius: 22,
          onTap: () => open(offset: const Offset(0, 20)),
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
            ),
            child: Icon(_modeIcon(mode), size: 18, color: colorScheme.primary),
          ),
        ),
      ),
      popup: CommonPopupMenu(
        items: [
          for (final item in Mode.values.where((m) => m != Mode.direct))
            PopupMenuItemData(
              icon: _modeIcon(item),
              label: _modeLabel(item),
              onPressed: () {
                globalState.appController.changeMode(item);
              },
            ),
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return _FocusableTap(
      borderRadius: 22,
      onTap: busy ? null : onTap,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: busy
                  ? CircularProgressIndicator(
                      strokeWidth: 2, color: colorScheme.primary)
                  : Icon(icon, size: 18, color: colorScheme.primary),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: context.textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
