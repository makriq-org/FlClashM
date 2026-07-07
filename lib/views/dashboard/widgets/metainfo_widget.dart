import 'package:flclashm/product/ui/dashboard/metainfo_widget_view.dart' as p;
import 'package:flclashm/views/profiles/add_profile.dart';
import 'package:flutter/widgets.dart';

class MetainfoWidget extends StatelessWidget {
  const MetainfoWidget({super.key});

  @override
  Widget build(BuildContext context) => p.MetainfoWidget(
        urlFormDialogBuilder: (_) => const URLFormDialog(),
      );
}
