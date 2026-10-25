import 'package:flclashx/ui/color.dart';
import 'package:flclashx/ui/inherited.dart';
import 'package:flclashx/ui/metrics.dart';
import 'package:flclashx/ui/scaffold.dart';
import 'package:flclashx/ui/typography.dart';
import 'package:flclashx/ui/view_scope.dart';
import 'package:material_ui/material_ui.dart';

extension BuildContextExtension on BuildContext {
  CommonScaffoldState? get commonScaffoldState {
    return findAncestorStateOfType<CommonScaffoldState>();
  }

  bool get isMobileView => ViewScope.isMobileOf(this, listen: false);

  void safeNestedPop<T extends Object?>([T? result]) {
    final nestedPop = SheetProvider.of(this)?.nestedNavigatorPop;
    if (nestedPop != null) {
      return nestedPop(result);
    } else {
      return Navigator.of(this).pop(result);
    }
  }

  bool get isInCompactSheet => SheetProvider.of(this)?.type.isCompact ?? false;

  /// Where a page's app bar ends, for a body built outside the scaffold's.
  double get appBarInset =>
      FloatingBarScope.of(this) ??
      (isInCompactSheet
          ? sheetAppBarHeight
          : MediaQuery.paddingOf(this).top + pageToolbarHeight);

  /// A compact sheet's header already trails its own gap.
  double get contentTopPadding =>
      TopInsetScope.of(this) ??
      (isInCompactSheet ? sheetAppBarHeight : appBarInset + 12);

  ColorScheme get colorScheme => Theme.of(this).colorScheme;

  bool get disableAnimations => MediaQuery.disableAnimationsOf(this);

  Duration motionDuration(Duration duration) =>
      disableAnimations ? Duration.zero : duration;

  TextStyle get listTitleStyle =>
      AppTextStyle.body.of(this).copyWith(color: colorScheme.onSurface);

  TextStyle get listSubtitleStyle => AppTextStyle.subheadline
      .of(this)
      .copyWith(color: colorScheme.onSurfaceVariant);

  TextStyle get listCaptionStyle => AppTextStyle.footnote
      .of(this)
      .copyWith(color: colorScheme.onSurfaceVariant);

  TextStyle get cardHeaderStyle => AppTextStyle.headline
      .of(this)
      .copyWith(color: colorScheme.onSurfaceVariant.opacity80);
}
