import 'package:flclashx/product/android/android_update_bridge.dart';
import 'package:flclashx/state.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestAndroidUpdateBridge extends AndroidUpdateBridge {
  _TestAndroidUpdateBridge({
    this.promptResult,
  });

  final bool? promptResult;
  int openLatestReleasePageCalls = 0;
  int showUpdateCheckErrorCalls = 0;
  String? promptedTagName;
  List<String>? promptedSubmits;

  @override
  Future<bool?> promptForUpdateDownload({
    required String tagName,
    required List<String> submits,
  }) async {
    promptedTagName = tagName;
    promptedSubmits = submits;
    return promptResult;
  }

  @override
  Future<void> showUpdateCheckError() async {
    showUpdateCheckErrorCalls++;
  }

  @override
  Future<bool> openLatestReleasePage() async {
    openLatestReleasePageCalls++;
    return true;
  }
}

void main() {
  group('AndroidUpdateBridge', () {
    setUp(() {
      globalState.isPre = false;
    });

    test(
        'opens latest release immediately after the update prompt is confirmed',
        () async {
      final bridge = _TestAndroidUpdateBridge(promptResult: true);

      await bridge.handleAppUpdateCheckResult(
        data: const {
          'tag_name': 'v1.2.3',
          'body': '- first change\n- second change',
        },
      );

      expect(bridge.promptedTagName, 'v1.2.3');
      expect(bridge.promptedSubmits, ['first change', 'second change']);
      expect(bridge.openLatestReleasePageCalls, 1);
      expect(bridge.showUpdateCheckErrorCalls, 0);
    });

    test('shows explicit update-check error when requested', () async {
      final bridge = _TestAndroidUpdateBridge();

      await bridge.handleAppUpdateCheckResult(
        data: null,
        handleError: true,
      );

      expect(bridge.openLatestReleasePageCalls, 0);
      expect(bridge.showUpdateCheckErrorCalls, 1);
    });
  });
}
