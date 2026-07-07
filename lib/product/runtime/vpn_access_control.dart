import '../../common/common.dart';
import '../../enum/enum.dart';
import '../../models/models.dart';

AccessControl enforceSelfPackageBypass(
  AccessControl accessControl, {
  List<String> selfPackageNames = const [packageName, '$packageName.dev'],
}) {
  final selfPackages = selfPackageNames
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toSet();
  if (selfPackages.isEmpty) {
    return accessControl;
  }

  if (!accessControl.enable) {
    return accessControl.copyWith(
      enable: true,
      mode: AccessControlMode.rejectSelected,
      rejectList: selfPackages.toList(growable: false),
    );
  }

  return switch (accessControl.mode) {
    AccessControlMode.acceptSelected => () {
        final acceptList = accessControl.acceptList
            .where((name) => !selfPackages.contains(name))
            .toList(growable: false);
        if (acceptList.isNotEmpty) {
          return accessControl.copyWith(acceptList: acceptList);
        }
        return accessControl.copyWith(
          mode: AccessControlMode.rejectSelected,
          acceptList: const [],
          rejectList: selfPackages.toList(growable: false),
        );
      }(),
    AccessControlMode.rejectSelected => accessControl.copyWith(
        rejectList: {
          ...accessControl.rejectList,
          ...selfPackages,
        }.toList(growable: false),
      ),
  };
}
