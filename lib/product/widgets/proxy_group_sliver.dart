import 'package:flutter/material.dart';

/// Each group reports its real header and exact row extents to the viewport.
/// Proxy rows stay lazy even when several large groups are expanded.
class ProxyGroupSliver extends StatelessWidget {
  const ProxyGroupSliver({
    super.key,
    required this.header,
    required this.expanded,
    required this.rowCount,
    required this.rowHeight,
    required this.spacing,
    required this.rowBuilder,
  });

  final Widget header;
  final bool expanded;
  final int rowCount;
  final double rowHeight;
  final double spacing;
  final IndexedWidgetBuilder rowBuilder;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: expanded ? 1 : 0, end: expanded ? 1 : 0),
    duration: kThemeAnimationDuration,
    curve: Curves.easeInOut,
    builder: (context, factor, _) => SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: header),
        if (factor > 0 && rowCount > 0)
          SliverPadding(
            padding: EdgeInsets.symmetric(vertical: 4 * factor),
            sliver: SliverFixedExtentList.builder(
              itemCount: rowCount,
              itemExtent: (rowHeight + spacing) * factor,
              itemBuilder: (context, index) => ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minHeight: rowHeight,
                  maxHeight: rowHeight,
                  child: ExcludeFocus(
                    excluding: !expanded,
                    child: Opacity(
                      opacity: factor,
                      child: rowBuilder(context, index),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
