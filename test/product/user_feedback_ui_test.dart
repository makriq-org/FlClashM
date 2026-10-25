import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/backend/backend_client.dart';
import 'package:flclashx/product/backend/frontend_settings.dart';
import 'package:flclashx/product/services/product_contributors.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/ui/list.dart';
import 'package:flclashx/views/about.dart';
import 'package:flclashx/views/config/general.dart';
import 'package:flclashx/views/logs.dart';
import 'package:flclashx/views/tools.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_app.dart';

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget child, {
  Config config = const Config(themeProps: ThemeProps()),
}) async {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      ...buildConfigOverrides(config),
      currentProfileProvider.overrideWith((ref) => null),
      navigationItemsStateProvider.overrideWith(
        (ref) => const NavigationItemsState(value: []),
      ),
    ],
  );
  addTearDown(container.dispose);
  globalState.container = container;
  globalState.packageInfo = PackageInfo(
    appName: 'FlClashM',
    packageName: 'com.makriq.flclash',
    version: '1.0.0',
    buildNumber: '1',
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TestApp(child: child),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

class _ArchivePicker extends FilePickerPlatform {
  final saved = Completer<(String, Uint8List)>();

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    saved.complete((fileName, bytes));
    return Uri.parse('content://test/diagnostics');
  }
}

void main() {
  testWidgets('About keeps fork and upstream credits and only intended links', (
    tester,
  ) async {
    await _pump(tester, const AboutView());
    final labels = tester.element(find.byType(AboutView)).appLocalizations;
    expect(find.text('Telegram'), findsNothing);
    expect(find.textContaining('t.me/'), findsNothing);
    expect(find.text('pluralplay'), findsOneWidget);
    expect(find.text('kastov'), findsOneWidget);
    final assets = await AssetManifest.loadFromAssetBundle(rootBundle);
    for (final contributor in productContributors) {
      expect(find.text(contributor.name), findsOneWidget);
      expect(find.byTooltip(contributor.link), findsOneWidget);
      expect(assets.listAssets(), contains(contributor.avatar));
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is CircleAvatar &&
              widget.foregroundImage == AssetImage(contributor.avatar),
        ),
        findsOneWidget,
      );
    }
    for (final (title, url) in [
      (labels.project, 'https://github.com/makriq-org/FlClashM'),
      (labels.originalRepository, 'https://github.com/pluralplay/FlClashX'),
    ]) {
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(find.text(url), findsOneWidget);
      await tester.tap(find.text(labels.cancel));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings has no top-level prerelease or export actions', (
    tester,
  ) async {
    await _pump(tester, const ToolsView());
    final labels = tester.element(find.byType(ToolsView)).appLocalizations;
    expect(find.text(labels.includePrereleaseUpdates), findsNothing);
    expect(find.text(labels.exportLogs), findsNothing);
    expect(find.text(labels.general), findsOneWidget);
    expect(find.text(labels.about), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final initiallyEnabled in [false, true]) {
    testWidgets(
      'General switch persists channel change from $initiallyEnabled through Go',
      (tester) async {
        final settings = <String, dynamic>{
          'includePrereleaseUpdates': initiallyEnabled,
          'skippedAppUpdateTagName': 'v1.1.0-pre1',
          'futureSetting': 'keep',
        };
        final patches = <Map>[];
        final client = BackendClient(
          events: const Stream.empty(),
          transport: (request) async {
            final method = request['method'];
            if (method == 'settings.patch') {
              final patch = (request['params'] as Map)['patch'] as Map;
              patches.add(patch);
              settings.addAll(
                Map<String, dynamic>.from(patch['appSetting'] as Map),
              );
            }
            return {
              'apiVersion': 1,
              'result': method == 'snapshot'
                  ? {
                      'seq': 1,
                      'runtime': {'instanceId': 'settings'},
                      'catalog': {
                        'revision': 1,
                        'profiles': [],
                        'settings': {'appSetting': settings},
                      },
                    }
                  : {'status': 'succeeded'},
            };
          },
        );
        await client.attach();
        addTearDown(client.detach);
        final initial = Config.fromJson(
          frontendSettings(client.sourceSettings),
        );
        expect(initial.appSettingProps.skippedAppUpdateTag, 'v1.1.0-pre1');
        final store = FrontendSettings(client: client)..project(initial);
        final container = await _pump(
          tester,
          const GeneralView(),
          config: initial,
        );
        final labels = tester
            .element(find.byType(GeneralView))
            .appLocalizations;
        final row = find.ancestor(
          of: find.text(labels.includePrereleaseUpdates),
          matching: find.byType(ListItem),
        );
        final toggle = find.descendant(of: row, matching: find.byType(Switch));
        expect(toggle.hitTestable(), findsOneWidget);
        expect(find.text(labels.includePrereleaseUpdatesDesc), findsOneWidget);
        final enabled = !initiallyEnabled;
        expect(tester.widget<Switch>(toggle).value, !enabled);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.widget<Switch>(toggle).value, enabled);
        await store.save(container.read(configProvider));
        await store.flush();
        final reloaded = Config.fromJson(
          frontendSettings(client.sourceSettings),
        );
        expect(reloaded.appSettingProps.includePrereleaseUpdates, enabled);
        expect(reloaded.appSettingProps.skippedAppUpdateTag, isEmpty);
        expect(settings['skippedAppUpdateTagName'], isEmpty);
        expect(settings['futureSetting'], 'keep');
        expect(settings.containsKey('skippedAppUpdateTag'), isFalse);
        expect(patches.first, {
          'appSetting': {
            'includePrereleaseUpdates': !initiallyEnabled,
            'skippedAppUpdateTagName': '',
          },
        });
        expect(patches, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'General opens Logs with navigation logs off and exports full ZIP',
    (tester) async {
      final temp = await tester.runAsync(
        () => Directory.systemTemp.createTemp('feedback-diagnostics'),
      );
      final directory = temp!;
      addTearDown(() => directory.delete(recursive: true));
      await tester.runAsync(() async {
        for (final (folder, name, text) in [
          ('logs', 'ui.log', 'ui log line'),
          ('diagnostics', 'flutter.0.log', 'flutter diagnostic line'),
          ('native', 'android-remote.0.log', 'remote diagnostic line'),
        ]) {
          final file = File('${directory.path}/$folder/$name');
          await file.parent.create(recursive: true);
          await file.writeAsString(text);
        }
      });
      final oldSupport = AppPath.supportDirectory;
      final oldTemp = AppPath.temporaryDirectory;
      final oldCache = AppPath.cacheDirectory;
      final oldDownload = AppPath.downloadDirectory;
      AppPath.supportDirectory = () async => directory;
      AppPath.temporaryDirectory = () async => directory;
      AppPath.cacheDirectory = () async => directory;
      AppPath.downloadDirectory = () async => directory;
      await appPath.rebind();
      addTearDown(() {
        AppPath.supportDirectory = oldSupport;
        AppPath.temporaryDirectory = oldTemp;
        AppPath.cacheDirectory = oldCache;
        AppPath.downloadDirectory = oldDownload;
      });
      const channel = MethodChannel('com.makriq.flclash/diagnostics');
      var snapshots = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'prepareSnapshot');
        snapshots++;
        return {
          'directory': '${directory.path}/native',
          'localFlushComplete': true,
          'remoteFlushRequested': true,
        };
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      PackageInfo.setMockInitialValues(
        appName: 'FlClashM',
        packageName: 'com.makriq.flclash',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
      final oldPicker = FilePickerPlatform.instance;
      final archivePicker = _ArchivePicker();
      FilePickerPlatform.instance = archivePicker;
      addTearDown(() => FilePickerPlatform.instance = oldPicker);
      final container = await _pump(tester, const GeneralView());
      expect(container.read(appSettingProvider).openLogs, isFalse);
      final labels = tester.element(find.byType(GeneralView)).appLocalizations;
      await tester.ensureVisible(find.text(labels.logs));
      await tester.tap(find.text(labels.logs));
      await tester.pumpAndSettle();
      expect(find.byType(LogsView), findsOneWidget);
      expect(find.byTooltip(labels.exportLogs).hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip(labels.exportLogs));
      // Drive platform-channel completions and real archive I/O together.
      for (
        var attempt = 0;
        attempt < 200 && !archivePicker.saved.isCompleted;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(
        archivePicker.saved.isCompleted,
        isTrue,
        reason: 'snapshots=$snapshots',
      );
      final saved = await archivePicker.saved.future;
      await tester.pumpAndSettle();
      expect(saved.$1, endsWith('.zip'));
      expect(snapshots, 1);
      final archive = ZipDecoder().decodeBytes(saved.$2);
      final contents = archive.files
          .where((file) => file.isFile)
          .map((file) => utf8.decode(file.content as List<int>))
          .join('\n');
      expect(contents, contains('ui log line'));
      expect(contents, contains('flutter diagnostic line'));
      expect(contents, contains('remote diagnostic line'));
      expect(contents, contains('"uiAttached": true'));
      expect(contents, contains('"remoteFlushRequested": true'));
      expect(find.text(labels.exportSuccess), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
