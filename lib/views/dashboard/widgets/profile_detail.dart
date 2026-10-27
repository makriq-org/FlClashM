import 'dart:async';
import 'dart:convert';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/ui/icons/icons.dart';
import 'package:flclashx/views/profiles/preview.dart';
import 'package:flclashx/views/profiles/profiles.dart';
import 'package:flclashx/views/proxies/providers.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

const _statSpacing = 8.0;

/// Whether the update went through; a failure has already been shown.
Future<bool> syncProfile(WidgetRef ref, Profile profile) async {
  final done = await globalState.loadingRun(() async {
    await ref
        .read(profilesActionProvider.notifier)
        .updateProfile(profile, showLoading: true);
    return true;
  }, tag: LoadingTag.profiles);
  return done ?? false;
}

void showProfileDetailSheet(BuildContext context) {
  showSheet<void>(context: context, builder: (_) => const ProfileDetailSheet());
}

void showProfilesSheet(BuildContext context) {
  showSheet<void>(
    context: context,
    builder: (_) => const ProfilesView(picker: true),
  );
}

typedef ProfileStats = ({int groups, int proxies, int rules, int providers});

ProfileStats profileStatsOf(
  ConfigCounts counts,
  List<ExternalProvider> providers,
) {
  final providedProxies = providers
      .where((provider) => provider.type == 'Proxy')
      .fold(0, (sum, provider) => sum + provider.count);
  return (
    groups: counts.groups,
    proxies: counts.proxies + providedProxies,
    rules: counts.rules,
    providers: providers.length,
  );
}

mixin ConfigCountsWatch<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  ConfigCounts? configCounts;
  bool configCountsFailed = false;
  var _generation = 0;
  (String?, int?)? _lastAppliedPlan;

  @override
  void initState() {
    super.initState();
    _lastAppliedPlan = ref
        .read(setupActionProvider.notifier)
        .appliedPlanRevision;
    final profile = ref.read(currentProfileProvider);
    if (profile != null) unawaited(_reloadCounts(profile.id));
  }

  Future<void> _reloadCounts(String profileId) async {
    final generation = ++_generation;
    try {
      final raw = await ref
          .read(setupActionProvider.notifier)
          .getProfileWithId(profileId, countsOnly: true);
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final counts = (
        groups: (data['groups'] as num).toInt(),
        proxies: (data['proxies'] as num).toInt(),
        rules: (data['rules'] as num).toInt(),
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        configCounts = counts;
        configCountsFailed = false;
      });
    } catch (error) {
      commonPrint.log('read profile counts error: $error');
      if (!mounted || generation != _generation) return;
      setState(() {
        configCounts = null;
        configCountsFailed = true;
      });
    }
  }

  void watchConfigCounts() {
    ref.listen(currentProfileProvider, (previous, next) {
      if (previous != next) {
        _generation++;
        setState(() {
          configCounts = null;
          configCountsFailed = false;
        });
        if (next != null) unawaited(_reloadCounts(next.id));
      }
    });
    ref.listen(groupsProvider, (previous, next) {
      final appliedPlan = ref
          .read(setupActionProvider.notifier)
          .appliedPlanRevision;
      final planChanged = appliedPlan != _lastAppliedPlan;
      _lastAppliedPlan = appliedPlan;
      // Empty projections are republished by unrelated backend events. A new
      // applied plan still needs fresh counts, even if it has no groups.
      if (!planChanged && previous?.isEmpty == true && next.isEmpty) return;
      final profile = ref.read(currentProfileProvider);
      if (profile != null) unawaited(_reloadCounts(profile.id));
    });
  }
}

class ProfileDetailSheet extends ConsumerStatefulWidget {
  const ProfileDetailSheet({super.key});

  @override
  ConsumerState<ProfileDetailSheet> createState() => _ProfileDetailSheetState();
}

class _ProfileDetailSheetState extends ConsumerState<ProfileDetailSheet>
    with ConfigCountsWatch<ProfileDetailSheet> {
  void _handlePreview(Profile profile) {
    unawaited(
      BaseNavigator.push<String>(context, PreviewProfileView(profile: profile)),
    );
  }

  @override
  Widget build(BuildContext context) {
    watchConfigCounts();
    final profile = ref.watch(currentProfileProvider);
    if (profile == null) {
      return const SizedBox.shrink();
    }
    final providers = ref.watch(providersProvider);
    final isUpdating = ref.watch(isUpdatingProvider(profile.updatingKey));
    final appLocalizations = context.appLocalizations;
    final subscriptionInfo = profile.subscriptionInfo;
    return CommonScaffold(
      title: profile.realLabel,
      iconActions: [
        if (profile.type == ProfileType.url)
          IconButtonData(
            glyph: AppGlyphs.sync,
            tooltip: appLocalizations.sync,
            isLoading: isUpdating,
            onPressed: () => syncProfile(ref, profile),
          ),
        IconButtonData(
          glyph: AppGlyphs.eye,
          tooltip: appLocalizations.runtimeConfig,
          onPressed: () => _handlePreview(profile),
        ),
      ],
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16)
                .copyWith(top: context.contentTopPadding, bottom: 20),
            sliver: SliverMainAxisGroup(
              slivers: [
                SliverList.list(
                  children: [
                    _StatsGrid(
                      stats: switch (configCounts) {
                        final counts? => profileStatsOf(counts, providers),
                        null => null,
                      },
                      failed: configCountsFailed,
                    ),
                    if (subscriptionInfo != null && subscriptionInfo.total > 0)
                      generateSection(
                        title: appLocalizations.subscriptionInfo,
                        items: [
                          ListItem(
                            title: SubscriptionInfoView(
                              subscriptionInfo: subscriptionInfo,
                            ),
                          ),
                        ],
                      ),
                    generateSection(
                      title: appLocalizations.profile,
                      items: [
                        _InfoRow(
                          label: appLocalizations.lastUpdated,
                          value: LastUpdateTimeText(
                            lastUpdateDate: profile.lastUpdateDate,
                          ),
                        ),
                        if (profile.type != ProfileType.custom)
                          _InfoRow(
                            label: appLocalizations.extendMode,
                            value: Text(
                              _extendLabel(context, profile.extendType),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                if (providers.isNotEmpty)
                  ExternalProvidersSliver(providers: providers),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _extendLabel(BuildContext context, ExtendType type) {
  return switch (type) {
    ExtendType.standard => context.appLocalizations.standard,
    ExtendType.script => context.appLocalizations.script,
  };
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.stats, required this.failed});

  final ProfileStats? stats;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final stats = this.stats;
    final tiles = [
      (appLocalizations.proxyGroup, stats?.groups),
      (appLocalizations.proxies, stats?.proxies),
      (appLocalizations.rules, stats?.rules),
      (appLocalizations.providers, stats?.providers),
    ];
    Widget rowOf(Iterable<(String, int?)> pair) {
      return Row(
        spacing: _statSpacing,
        children: [
          for (final (label, value) in pair)
            Expanded(
              child: _StatTile(
                label: label,
                value: value?.toString() ?? (failed ? '-' : null),
              ),
            ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        spacing: _statSpacing,
        children: [rowOf(tiles.take(2)), rowOf(tiles.skip(2))],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: ShapeDecoration(
        color: context.raisedSurfaceLevel.colorOf(colorScheme),
        shape: AppShape.all(AppCorner.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 2,
        children: [
          Text(
            value ?? '0',
            maxLines: 1,
            style: AppTextStyle.title2
                .of(context, emphasized: true)
                .copyWith(color: colorScheme.onSurface),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyle.footnote
                .of(context)
                .copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    return ListItem(
      title: Text(label),
      trailing: DefaultTextStyle.merge(
        style: AppTextStyle.subheadline
            .of(context)
            .copyWith(color: context.colorScheme.onSurfaceVariant),
        child: value,
      ),
    );
  }
}
