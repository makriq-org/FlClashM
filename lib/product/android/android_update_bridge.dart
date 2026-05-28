import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../common/common.dart';
import '../../plugins/app.dart';
import '../../state.dart';

abstract interface class AppUpdatePlatformBridge {
  String get latestReleaseUrl;

  Future<Map<String, dynamic>?> checkForAppUpdate();

  Future<bool?> promptForUpdateDownload({
    required String tagName,
    required List<String> submits,
  });

  Future<void> showUpdateCheckError();

  Future<bool> openLatestReleasePage();

  Future<bool> installPackage(String path);
}

class AndroidUpdateBridge implements AppUpdatePlatformBridge {
  const AndroidUpdateBridge();

  @override
  String get latestReleaseUrl =>
      'https://github.com/$repository/releases/latest';

  @override
  Future<Map<String, dynamic>?> checkForAppUpdate() => request.checkForUpdate();

  @visibleForTesting
  @override
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
  @override
  Future<void> showUpdateCheckError() async {
    await globalState.showMessage(
      title: appLocalizations.checkUpdate,
      message: TextSpan(text: appLocalizations.checkUpdateError),
    );
  }

  @visibleForTesting
  @override
  Future<bool> openLatestReleasePage() =>
      launchUrl(Uri.parse(latestReleaseUrl));

  @override
  Future<bool> installPackage(String path) async =>
      await app?.openFile(path) ?? false;
}
