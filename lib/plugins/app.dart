import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flclashx/common/app_localizations.dart';
import 'package:flclashx/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

class App {

  factory App() {
    _instance ??= App._internal();
    return _instance!;
  }

  App._internal() {
    methodChannel = const MethodChannel("app");
    methodChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case "exit":
          if (onExit != null) {
            await onExit!();
          }
        case "getText":
          try {
            return Intl.message(call.arguments as String);
          } catch (_) {
            return "";
          }
        default:
          throw MissingPluginException();
      }
    });
  }
  static App? _instance;
  late MethodChannel methodChannel;
  Function()? onExit;

  Future<bool?> moveTaskToBack() async => methodChannel.invokeMethod<bool>("moveTaskToBack");

  Future<List<Package>> getPackages() async {
    final packagesString =
        await methodChannel.invokeMethod<String>("getPackages");
    return Isolate.run<List<Package>>(() {
      final List<dynamic> packagesRaw =
          packagesString != null ? json.decode(packagesString) : [];
      return packagesRaw.map((e) => Package.fromJson(e)).toSet().toList();
    });
  }

  Future<List<String>> getChinaPackageNames() async {
    final packageNamesString =
        await methodChannel.invokeMethod<String>("getChinaPackageNames");
    return Isolate.run<List<String>>(() {
      final List<dynamic> packageNamesRaw =
          packageNamesString != null ? json.decode(packageNamesString) : [];
      return packageNamesRaw.map((e) => e.toString()).toList();
    });
  }

  Future<bool> openFile(String path) async => await methodChannel.invokeMethod<bool>("openFile", {
          "path": path,
        }) ??
        false;

  final _iconCache = <String, ImageProvider?>{};
  final _iconFutures = <String, Future<ImageProvider?>>{};

  Future<ImageProvider?> getPackageIcon(String packageName) {
    if (_iconCache.containsKey(packageName)) {
      return Future.value(_iconCache[packageName]);
    }
    return _iconFutures[packageName] ??= _fetchIcon(packageName);
  }

  Future<ImageProvider?> _fetchIcon(String packageName) async {
    final base64 = await methodChannel.invokeMethod<String>("getPackageIcon", {
      "packageName": packageName,
    });
    final icon = base64 != null ? MemoryImage(base64Decode(base64)) : null;
    _iconCache[packageName] = icon;
    _iconFutures.remove(packageName);
    return icon;
  }

  Future<bool?> tip(String? message) async => methodChannel.invokeMethod<bool>("tip", {
      "message": "$message",
    });

  Future<bool?> initShortcuts() async => methodChannel.invokeMethod<bool>(
      "initShortcuts",
      <String, String>{
        "toggle": appLocalizations.toggle,
        "start": appLocalizations.start,
        "stop": appLocalizations.stop,
      },
    );

  Future<bool?> updateExcludeFromRecents(bool value) async => methodChannel.invokeMethod<bool>("updateExcludeFromRecents", {
      "value": value,
    });
}

final app = Platform.isAndroid ? App() : null;
