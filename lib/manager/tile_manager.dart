import 'dart:async';

import 'package:flclashx/plugins/tile.dart';
import 'package:flclashx/state.dart';
import 'package:flutter/material.dart';

class TileManager extends StatefulWidget {
  const TileManager({
    super.key,
    required this.child,
  });
  final Widget child;

  @override
  State<TileManager> createState() => _TileContainerState();
}

class _TileContainerState extends State<TileManager> {
  @override
  Widget build(BuildContext context) => widget.child;

  @override
  void initState() {
    super.initState();
    // Push current mode to native so widget picks up the right active button
    // when the main engine comes online.
    try {
      final current = globalState.config.patchClashConfig.mode.name;
      unawaited(tile?.updateMode(current));
    } catch (_) {}
  }

  @override
  void dispose() => super.dispose();
}
