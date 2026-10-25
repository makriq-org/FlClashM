import 'package:flclashx/ui/flutter_material_compat.dart';
import 'package:flclashx/widgets/dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as ui;

void main() {
  testWidgets('long update notes scroll inside a small dialog', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ui.MaterialApp(
        localizationsDelegates: flutterMaterialLocalizations,
        builder: (context, child) => FlutterMaterialCompat(child: child!),
        home: CommonDialog(
          title: 'Update',
          actions: [TextButton(onPressed: () {}, child: const Text('Install'))],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [for (var i = 0; i < 100; i++) Text('Change $i')],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -10000),
    );
    await tester.pumpAndSettle();
    expect(find.text('Change 99').hitTestable(), findsOneWidget);
    expect(find.text('Install').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('download progress keeps its own layout', (tester) async {
    await tester.pumpWidget(
      ui.MaterialApp(
        localizationsDelegates: flutterMaterialLocalizations,
        builder: (context, child) => FlutterMaterialCompat(child: child!),
        home: const CommonDialog(
          title: 'Downloading',
          overrideScroll: true,
          child: SizedBox(
            height: 80,
            child: LinearProgressIndicator(value: .5),
          ),
        ),
      ),
    );
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
