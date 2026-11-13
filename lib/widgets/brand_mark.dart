import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

import '../common/constant.dart';

/// Render the mark directly from paths at the final device resolution.
/// The daylight palette preserves the silhouette without a hairline outline.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, required this.size});

  final double size;

  static String assetFor(Brightness brightness) =>
      brightness == Brightness.light
      ? 'assets/images/brand_mark_light.svg'
      : 'assets/images/brand_mark.svg';

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    assetFor(Theme.of(context).brightness),
    width: size,
    height: size,
    semanticsLabel: appName,
  );
}
