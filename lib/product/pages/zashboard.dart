import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../widgets/widgets.dart';

/// The panel only consumes the controller selected through Go settings.
Future<void> openProductZashboard(
  BuildContext context,
  String url, {
  required bool inApp,
}) async {
  if (inApp && (Platform.isAndroid || Platform.isIOS)) {
    await BaseNavigator.push(context, ProductZashboardPage(url: url));
  } else {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}

class ProductZashboardPage extends StatefulWidget {
  const ProductZashboardPage({super.key, required this.url});
  final String url;

  @override
  State<ProductZashboardPage> createState() => _ProductZashboardPageState();
}

class _ProductZashboardPageState extends State<ProductZashboardPage> {
  late final WebViewController _controller;
  int _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await _controller.setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) {
            if (mounted) setState(() => _progress = value);
          },
          onWebResourceError: (error) {
            if (mounted && error.isForMainFrame == true) {
              setState(() => _error = error.description);
            }
          },
        ),
      );
      await _controller.loadRequest(Uri.parse(widget.url));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Zashboard'),
      actions: [
        IconButton(
          icon: const Icon(Icons.open_in_browser),
          onPressed: () async {
            await launchUrl(
              Uri.parse(widget.url),
              mode: LaunchMode.externalApplication,
            );
          },
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: () async {
            setState(() => _error = null);
            await _controller.reload();
          },
        ),
      ],
    ),
    body: Column(
      children: [
        if (_progress < 100) LinearProgressIndicator(value: _progress / 100),
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            actions: [
              TextButton(
                onPressed: () {
                  setState(() => _error = null);
                },
                child: const Icon(Icons.close),
              ),
            ],
          ),
        Expanded(child: WebViewWidget(controller: _controller)),
      ],
    ),
  );
}
