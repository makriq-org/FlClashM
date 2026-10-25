import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Compatibility surface for the product APK updater.
class CommonDialog extends StatelessWidget {
  const CommonDialog({
    super.key,
    this.title,
    required this.child,
    this.actions = const [],
    this.padding,
    this.overrideScroll = false,
  });

  final String? title;
  final Widget child;
  final List<Widget> actions;
  final EdgeInsetsGeometry? padding;
  final bool overrideScroll;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: title == null ? null : Text(title!),
      contentPadding: padding,
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 300,
          maxHeight: math.min(500, size.height * .6),
        ),
        child: overrideScroll ? child : SingleChildScrollView(child: child),
      ),
      actions: actions,
    );
  }
}
