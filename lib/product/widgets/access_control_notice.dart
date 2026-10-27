import 'package:flclashx/widgets/managed_setting.dart';
import 'package:flutter/widgets.dart';

class ProductAccessControlNotice extends StatelessWidget {
  const ProductAccessControlNotice({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) =>
      ManagedSettingsMessage(message: message, warning: true);
}
