import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../common/common.dart';
import '../../plugins/app.dart';
import '../../state.dart';

class AndroidUpdateBridge {
  const AndroidUpdateBridge();

  String get latestReleaseUrl =>
      'https://github.com/$repository/releases/latest';

  Future<Map<String, dynamic>?> checkForAppUpdate() => request.checkForUpdate();

  Future<void> autoCheckForAppUpdate({required bool enabled}) async {
    if (!enabled) {
      return;
    }
    final data = await checkForAppUpdate();
    await handleAppUpdateCheckResult(data: data);
  }

  Future<void> checkAndHandleAppUpdate({bool handleError = false}) async {
    final data = await checkForAppUpdate();
    await handleAppUpdateCheckResult(
      data: data,
      handleError: handleError,
    );
  }

  Future<void> handleAppUpdateCheckResult({
    Map<String, dynamic>? data,
    bool handleError = false,
  }) async {
    if (globalState.isPre) {
      return;
    }

    if (data != null) {
      final tagName = data['tag_name'];
      final body = data['body'];
      final submits = utils.parseReleaseBody(body);
      final res = await promptForUpdateDownload(
        tagName: '$tagName',
        submits: submits,
      );
      if (res ?? false) {
        await openLatestReleasePage();
      }
      return;
    }

    if (handleError) {
      await showUpdateCheckError();
    }
  }

  @visibleForTesting
  Future<bool?> promptForUpdateDownload({
    required String tagName,
    required List<String> submits,
  }) async {
    final textTheme = globalState.navigatorKey.currentContext?.textTheme;
    return globalState.showMessage(
      title: appLocalizations.discoverNewVersion,
      message: TextSpan(
        text: "$tagName \n",
        style: textTheme?.headlineSmall,
        children: [
          TextSpan(text: "\n", style: textTheme?.bodyMedium),
          for (final submit in submits)
            TextSpan(text: "- $submit \n", style: textTheme?.bodyMedium),
        ],
      ),
      confirmText: appLocalizations.goDownload,
    );
  }

  @visibleForTesting
  Future<void> showUpdateCheckError() async {
    await globalState.showMessage(
      title: appLocalizations.checkUpdate,
      message: TextSpan(text: appLocalizations.checkUpdateError),
    );
  }

  @visibleForTesting
  Future<bool> openLatestReleasePage() =>
      launchUrl(Uri.parse(latestReleaseUrl));

  Future<bool> installPackage(String path) async =>
      await app?.openFile(path) ?? false;
}
