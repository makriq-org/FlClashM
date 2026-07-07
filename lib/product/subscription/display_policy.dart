import '../../enum/enum.dart';
import '../../models/models.dart';
import 'provider_advisory.dart';

class ProductSubscriptionDisplayPolicy {
  const ProductSubscriptionDisplayPolicy();

  List<Group> selectVisibleGroups({
    required Mode mode,
    required List<Group> groups,
    required bool globalOverrideEnabled,
  }) =>
      switch (mode) {
        Mode.direct => const [],
        Mode.global => globalOverrideEnabled
            ? groups
                .where((item) => item.name == GroupName.GLOBAL.name)
                .toList()
            : groups.toList(),
        Mode.rule => groups
            .where((item) => item.hidden == false)
            .where((item) => item.name != GroupName.GLOBAL.name)
            .toList(),
      };

  ProductProviderAdvisory advisoryForProfile(Profile? profile) =>
      ProductProviderAdvisory.fromProfile(profile);

  ProductDisplayHints displayHintsForProfile(Profile? profile) =>
      advisoryForProfile(profile).display;

  bool resolveEffectiveNewDashboard({
    required bool? settingValue,
    required ProductDisplayHints displayHints,
  }) =>
      settingValue ?? displayHints.newDashboard;

  bool isDashboardEditingLocked({
    required bool effectiveNewDashboard,
    required ProductDisplayHints displayHints,
  }) =>
      displayHints.denyDashboardEditing || effectiveNewDashboard;

  String resolveNotificationTitle(Profile profile) {
    final displayHints = displayHintsForProfile(profile);
    if (displayHints.serviceName.isNotEmpty) {
      return displayHints.serviceName;
    }
    return profile.label ?? profile.id;
  }

  String resolveNotificationSupportUrl(Profile profile) =>
      displayHintsForProfile(profile).supportUrl;
}

const productSubscriptionDisplayPolicy = ProductSubscriptionDisplayPolicy();
