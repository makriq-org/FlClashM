import 'package:material_ui/material_ui.dart';
class CommonDialog extends StatelessWidget {
 const CommonDialog({super.key,this.title,required this.child,this.actions=const [],this.padding,this.overrideScroll=false});
 final bool overrideScroll;
 final String? title;final Widget child;final List<Widget> actions;final EdgeInsetsGeometry? padding;
 @override
 Widget build(BuildContext context)=>AlertDialog(title:title==null?null:Text(title!),content:child,actions:actions,contentPadding:padding);
}
