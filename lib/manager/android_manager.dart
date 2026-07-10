import 'dart:async';

import 'package:flclashm/product/services/product_services.dart';
import 'package:flclashm/providers/config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AndroidManager extends ConsumerStatefulWidget {
  const AndroidManager({
    super.key,
    required this.child,
  });
  final Widget child;

  @override
  ConsumerState<AndroidManager> createState() => _AndroidContainerState();
}

class _AndroidContainerState extends ConsumerState<AndroidManager> {
  @override
  void initState() {
    super.initState();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    ref.listenManual(
      appSettingProvider.select((state) => state.hidden),
      (prev, next) {
        unawaited(
          productServices.androidShell.updateExcludeFromRecents(hidden: next),
        );
      },
      fireImmediately: true,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
