import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

// App-wide mobile bottom navigation rendered as a single rounded "segmented selector"
// bar: every navigation destination is an equal-width icon segment, and a primary
// pill slides under the active one. Mobile only — desktop keeps its side rail.
class HeroNavBar extends ConsumerWidget {
  const HeroNavBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMobile = ref.watch(isMobileViewProvider);
    if (!isMobile) return const SizedBox.shrink();
    final items = ref.watch(currentNavigationsStateProvider).value;
    if (items.length < 2) return const SizedBox.shrink();
    final current = ref.watch(currentPageLabelProvider);
    final colorScheme = context.colorScheme;

    final rawIndex = items.indexWhere((e) => e.label == current);
    final selectedIndex = rawIndex < 0 ? 0 : rawIndex;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Container(
          height: 58,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(29),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.10),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final segWidth = constraints.maxWidth / items.length;
              return Stack(
                children: [
                  // Sliding highlight pill behind the active segment.
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    left: segWidth * selectedIndex,
                    top: 0,
                    bottom: 0,
                    width: segWidth,
                    child: Container(
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        borderRadius: BorderRadius.circular(23),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < items.length; i++)
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () =>
                                globalState.appController.toPage(items[i].label),
                            child: Tooltip(
                              message: items[i].label == PageLabel.proxies
                                  ? appLocalizations.locations
                                  : Intl.message(items[i].label.name),
                              child: Center(
                                child: AnimatedScale(
                                  duration: const Duration(milliseconds: 260),
                                  curve: Curves.easeOutCubic,
                                  scale: i == selectedIndex ? 1.0 : 0.92,
                                  child: Icon(
                                    items[i].icon.icon ?? Icons.circle,
                                    size: 26,
                                    color: i == selectedIndex
                                        ? colorScheme.onPrimary
                                        : colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
