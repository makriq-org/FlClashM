import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/widgets/text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

String _countryCodeToEmoji(String code) {
  if (code.length != 2) return code;
  final upper = code.toUpperCase();
  final first = 0x1F1E6 - 0x41 + upper.codeUnitAt(0);
  final second = 0x1F1E6 - 0x41 + upper.codeUnitAt(1);
  return String.fromCharCodes([first, second]);
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

(String, String) _splitBytes(int bytes) {
  if (bytes <= 0) return ('0', 'B');
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return (value.toStringAsFixed(1), units[i]);
}

class StatsGrid extends ConsumerWidget {
  const StatsGrid({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runTime = ref.watch(runTimeProvider);
    final profile = ref.watch(currentProfileProvider);
    final sub = profile?.subscriptionInfo;
    final hasTraffic = sub != null && sub.total > 0;
    final hasExpire = sub != null && sub.expire > 0;

    return ValueListenableBuilder(
      valueListenable: detectionState.state,
      builder: (_, networkState, __) {
        final ipInfo = networkState.ipInfo;
        final isLoading = networkState.isTesting;
        final ipText = ipInfo?.ip ?? '—';
        final country = ipInfo?.countryCode ?? '';
        final flag = country.isNotEmpty ? _countryCodeToEmoji(country) : null;

        return Column(
          children: [
            if (hasTraffic || hasExpire) ...[
              Row(
                children: [
                  if (hasExpire)
                    Expanded(child: _ExpiryPill(timestamp: sub!.expire))
                  else
                    const Expanded(child: SizedBox.shrink()),
                  const SizedBox(width: 8),
                  if (hasTraffic)
                    Expanded(child: _TrafficPill(sub: sub!))
                  else
                    const Expanded(child: SizedBox.shrink()),
                ],
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Expanded(
                  child: _IpPill(ip: ipText, flag: flag, isLoading: isLoading),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatPill(
                    icon: Icons.timer_outlined,
                    label: runTime != null ? utils.getTimeText(runTime) : '—',
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _IpPill extends StatelessWidget {
  const _IpPill({required this.ip, this.flag, this.isLoading = false});

  final String ip;
  final String? flag;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () {
        if (!detectionState.forceCheck()) {
          context.showNotifier(appLocalizations.tooFrequentOperation);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.7),
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            if (isLoading)
              SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2, color: colorScheme.onSurfaceVariant,
                ),
              )
            else
              Icon(Icons.public_rounded, size: 14, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                ip,
                style: context.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontFamily: FontFamily.jetBrainsMono.value,
                ),
                maxLines: 1, overflow: TextOverflow.ellipsis,
              ),
            ),
            if (flag != null) ...[
              const SizedBox(width: 6),
              EmojiText(flag!, style: context.textTheme.labelMedium),
            ],
          ],
        ),
      ),
    );
  }
}

class _TrafficPill extends StatelessWidget {
  const _TrafficPill({required this.sub});

  final SubscriptionInfo sub;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final used = sub.upload + sub.download;
    final total = sub.total;
    final progress = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final fillColor = progress > 0.9
        ? Colors.red.shade400.withValues(alpha: 0.25)
        : progress > 0.7
            ? Colors.orange.shade400.withValues(alpha: 0.2)
            : colorScheme.primary.withValues(alpha: 0.15);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.7),
          width: 1.5,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12.5),
        child: Stack(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
              child: Row(
                children: [
                  Icon(Icons.data_usage_rounded, size: 14, color: colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_splitBytes(used).$1} / ${_formatBytes(total)}',
                      style: context.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Positioned.fill(
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: progress,
                child: Container(color: fillColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpiryPill extends StatelessWidget {
  const _ExpiryPill({required this.timestamp});

  final int timestamp;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final now = DateTime.now();
    final isExpired = date.isBefore(now);
    final formatted = DateFormat.yMMMd().format(date);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isExpired ? Icons.warning_amber_rounded : Icons.event_rounded,
            size: 14,
            color: isExpired ? Colors.red.shade400 : colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          if (!isExpired)
            Text(
              '${appLocalizations.untilDate} ',
              style: context.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
          Expanded(
            child: Text(
              formatted,
              style: context.textTheme.labelSmall?.copyWith(
                color: isExpired ? Colors.red.shade400 : colorScheme.onSurfaceVariant,
              ),
              maxLines: 1, overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  const _StatPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: context.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontFamily: FontFamily.jetBrainsMono.value,
              ),
              maxLines: 1, overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
