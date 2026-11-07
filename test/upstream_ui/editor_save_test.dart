import 'dart:async';

import 'package:code_forge/code_forge.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/pages/editor.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flutter/services.dart';
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

  for (final leave in [false, true]) {
    testWidgets(
      '${leave ? 'navigation' : 'save'} includes an already running large replaceAll',
      (tester) async {
        final original = 'key: old # ${'x' * 256}\n' * 600;
        String? savedText;
        var replacementFinished = false;
        var savedAfterReplacement = false;
        await tester.pumpWidget(
          TestApp(
            wrapInProviderScope: true,
            overrides: [
              appSettingProvider.overrideWithBuild(
                (_, _) => const AppSettingProps(),
              ),
            ],
            child: EditorPage(
              title: 'Before',
              content: original,
              titleEditable: true,
              onSave: (_, _, content) {
                savedText = content;
                savedAfterReplacement = replacementFinished;
              },
              onPop: (_, _, content) async {
                savedText = content;
                savedAfterReplacement = replacementFinished;
                return false;
              },
            ),
          ),
        );
        await tester.pump();
        for (
          var i = 0;
          i < 100 && find.byType(CodeForge).evaluate().isEmpty;
          i++
        ) {
          await settle(tester, 1);
        }
        expect(find.byType(CodeForge), findsOneWidget);
        final forge = tester.widget<CodeForge>(find.byType(CodeForge));
        expect(forge.controller.length, original.length);
        final finder = forge.findController!
          ..isActive = true
          ..findInputController.text = 'old';
        for (var i = 0; i < 100 && finder.matchCount != 600; i++) {
          await settle(tester, 1);
        }
        expect(finder.matchCount, 600);
        // Keep Save available before the asynchronous replacement has changed text.
        await tester.enterText(
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField && widget.controller?.text == 'Before',
          ),
          'After',
        );
        await tester.pump();
        finder.replaceInputController.text = 'new';
        final shortcuts = tester.widget<CallbackShortcuts>(
          find
              .ancestor(
                of: find.byType(EditorView),
                matching: find.byType(CallbackShortcuts),
              )
              .first,
        );
        final save = shortcuts.bindings.entries
            .firstWhere(
              (entry) =>
                  entry.key is SingleActivator &&
                  (entry.key as SingleActivator).trigger ==
                      LogicalKeyboardKey.keyS,
            )
            .value;
        // No event-loop gap: Save starts while replaceAll is awaiting native bytes.
        await tester.runAsync(() async {
          final replacement = finder.replaceAll().then(
            (_) => replacementFinished = true,
          );
          if (leave) {
            unawaited(
              Navigator.of(tester.element(find.byType(EditorPage))).maybePop(),
            );
          } else {
            save();
          }
          expect(savedText, isNull);
          await replacement;
        });
        await settle(tester);
        expect(savedAfterReplacement, isTrue);
        expect(
          savedText == original.replaceAll('old', 'new'),
          isTrue,
          reason: 'Save must contain the completed replacement, not its old snapshot',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}
