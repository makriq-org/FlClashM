import 'package:flclashm/product/ui/dashboard/dashboard_view.dart' as p;
import 'package:flutter/widgets.dart';

import 'widgets/hero_connect.dart';
import 'widgets/start_button.dart';

class DashboardView extends StatelessWidget {
  const DashboardView({super.key});

  @override
  Widget build(BuildContext context) => p.DashboardView(
        heroConnectBuilder: (_) => const HeroConnect(),
        startButtonBuilder: (_) => const StartButton(),
      );
}
