import 'dart:async';

import 'package:code_forge/code_forge.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/pages/editor.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';
import 'code_forge/support.dart' show initEditorNative, settle;

void main() {
  setUpAll(initEditorNative);

  testWidgets('pending document save blocks editing and back until completion', (
    tester,
  ) async {
    final saving = Completer<void>();
    var saves = 0;
    var popPrompts = 0;
    String? savedTitle;
    String? savedText;
    await tester.pumpWidget(
      TestApp(
        wrapInProviderScope: true,
        overrides: [
          appSettingProvider.overrideWithBuild(
            (_, _) => const AppSettingProps(),
          ),
        ],
        child: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => EditorPage(
                    title: 'Before',
                    content: 'mode: rule\n',
                    titleEditable: true,
                    onSave: (_, title, content) {
                      saves++;
                      savedTitle = title;
                      savedText = content;
                      return saving.future;
                    },
                    onPop: (_, _, _) async {
                      popPrompts++;
                      return true;
                    },
                  ),
                ),
              ),
              child: const Text('Open document'),
            ),
          ),
        ),
      ),
    );
    // TestApp uses the application's navigator; retain its real route instance.
    await tester.tap(find.text('Open document'));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(find.byType(CodeForge), findsOneWidget);
    final title = find.byType(TextField);
    await tester.enterText(title, 'After');
    await tester.pump();
    await tester.tap(find.byTooltip(currentAppLocalizations.save));
    await settle(tester);
    expect(saves, 1);
    expect(savedTitle, 'After');
    expect(savedText, 'mode: rule\n');
    expect(tester.widget<TextField>(title).enabled, isFalse);
    expect(tester.widget<CodeForge>(find.byType(CodeForge)).readOnly, isTrue);
    final nav = Navigator.of(tester.element(find.byType(EditorPage)));
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(EditorPage), findsOneWidget);
    expect(popPrompts, 0);

    saving.complete();
    await settle(tester);
    expect(tester.widget<TextField>(title).enabled, isTrue);
    expect(tester.widget<CodeForge>(find.byType(CodeForge)).readOnly, isFalse);
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(EditorPage), findsNothing);
    expect(popPrompts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
