import 'package:flclashm/product/ui/dashboard/hero_connect_view.dart' as p;
import 'package:flclashm/views/profiles/add_profile.dart';
import 'package:flutter/widgets.dart';

class HeroConnect extends StatelessWidget {
  const HeroConnect({super.key});

  @override
  Widget build(BuildContext context) =>
      p.HeroConnect(urlFormDialogBuilder: (_) => const URLFormDialog());
}
