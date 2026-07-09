import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lpinyin/lpinyin.dart';

class Utils {
  Color? getDelayColor(int? delay) {
    if (delay == null) return null;
    if (delay < 0) return Colors.red;
    if (delay < 600) return Colors.green;
    return const Color(0xFFC57F0A);
  }

  String get id {
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final random = Random();
    final randomStr =
        String.fromCharCodes(List.generate(8, (_) => random.nextInt(26) + 97));
    return "$timestamp$randomStr";
  }

  String getDateStringLast2(int value) {
    final valueRaw = "0$value";
    return valueRaw.substring(
      valueRaw.length - 2,
    );
  }

  String generateRandomString({int minLength = 10, int maxLength = 100}) {
    const latinChars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random();

    final length = minLength + random.nextInt(maxLength - minLength + 1);

    var result = '';
    for (var i = 0; i < length; i++) {
      if (random.nextBool()) {
        result +=
            String.fromCharCode(0x4E00 + random.nextInt(0x9FA5 - 0x4E00 + 1));
      } else {
        result += latinChars[random.nextInt(latinChars.length)];
      }
    }

    return result;
  }

  String get uuidV4 {
    final random = Random();
    final bytes = List.generate(16, (_) => random.nextInt(256));

    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    final hex =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  String getTimeDifference(DateTime dateTime) {
    final currentDateTime = DateTime.now();
    final difference = currentDateTime.difference(dateTime);
    final inHours = difference.inHours;
    final inMinutes = difference.inMinutes;
    final inSeconds = difference.inSeconds;

    return "${getDateStringLast2(inHours)}:${getDateStringLast2(inMinutes)}:${getDateStringLast2(inSeconds)}";
  }

  String getTimeText(int? timeStamp) {
    if (timeStamp == null) {
      return '00:00:00';
    }
    final diff = timeStamp / 1000;
    final totalSeconds = diff.floor();

    const maxSeconds = 31 * 86400 + 23 * 3600 + 59 * 60 + 59;
    if (totalSeconds >= maxSeconds) {
      return "Seriously?";
    }

    final days = (totalSeconds / 86400).floor();
    final hours = ((totalSeconds % 86400) / 3600).floor();
    final minutes = ((totalSeconds % 3600) / 60).floor();
    final seconds = (totalSeconds % 60).floor();

    if (days == 0) {
      return "${getDateStringLast2(hours)}:${getDateStringLast2(minutes)}:${getDateStringLast2(seconds)}";
    }

    return "${days}d ${getDateStringLast2(hours)}:${getDateStringLast2(minutes)}:${getDateStringLast2(seconds)}";
  }

  Locale? getLocaleForString(String? localString) {
    if (localString == null) return null;
    final localSplit = localString.split("_");
    if (localSplit.length == 1) {
      return Locale(localSplit[0]);
    }
    if (localSplit.length == 2) {
      return Locale(localSplit[0], localSplit[1]);
    }
    if (localSplit.length == 3) {
      return Locale.fromSubtags(
          languageCode: localSplit[0],
          scriptCode: localSplit[1],
          countryCode: localSplit[2]);
    }
    return null;
  }

  int sortByChar(String a, String b) {
    if (a.isEmpty && b.isEmpty) {
      return 0;
    }
    if (a.isEmpty) {
      return -1;
    }
    if (b.isEmpty) {
      return 1;
    }
    final charA = a[0];
    final charB = b[0];

    if (charA == charB) {
      return sortByChar(a.substring(1), b.substring(1));
    } else {
      return charA.compareToLower(charB);
    }
  }

  String getOverwriteLabel(String label) {
    final reg = RegExp(r'\((\d+)\)$');
    final matches = reg.allMatches(label);
    if (matches.isNotEmpty) {
      final match = matches.last;
      final number = int.parse(match[1] ?? '0') + 1;
      return label.replaceFirst(reg, '($number)');
    } else {
      return "$label(1)";
    }
  }

  String getTrayIconPath({
    required Brightness brightness,
    bool isRunning = false,
    bool? isSystemDark,
  }) {
    if (Platform.isMacOS) {
      return "assets/images/icon_white.png";
    }

    if (isRunning) {
      return "assets/images/icon.ico";
    }

    final effectiveBrightness = isSystemDark != null
        ? (isSystemDark ? Brightness.dark : Brightness.light)
        : brightness;

    return switch (effectiveBrightness) {
      Brightness.dark => "assets/images/icon_stop_white.ico",
      Brightness.light => "assets/images/icon_stop_black.ico",
    };
  }

  int compareVersions(String version1, String version2) {
    final first = _ParsedVersion.parse(version1);
    final second = _ParsedVersion.parse(version2);
    return first.compareTo(second);
  }

  String getPinyin(String value) => value.isNotEmpty
      ? PinyinHelper.getFirstWordPinyin(value.substring(0, 1))
      : "";

  String? getFileNameForDisposition(String? disposition) {
    if (disposition == null) return null;
    final parseValue = HeaderValue.parse(disposition);
    final parameters = parseValue.parameters;
    final fileNamePointKey = parameters.keys
        .firstWhere((key) => key == "filename*", orElse: () => "");
    if (fileNamePointKey.isNotEmpty) {
      final res = parameters[fileNamePointKey]?.split("''") ?? [];
      if (res.length >= 2) {
        return Uri.decodeComponent(res[1]);
      }
    }
    final fileNameKey = parameters.keys
        .firstWhere((key) => key == "filename", orElse: () => "");
    if (fileNameKey.isEmpty) return null;
    return parameters[fileNameKey];
  }

  FlutterView getScreen() =>
      WidgetsBinding.instance.platformDispatcher.views.first;

  List<String> parseReleaseBody(String? body) {
    if (body == null) return [];
    const pattern = r'- \s*(.*)';
    final regex = RegExp(pattern);
    return regex
        .allMatches(body)
        .map((match) => match.group(1) ?? '')
        .where((item) => item.isNotEmpty)
        .toList();
  }

  ViewMode getViewMode(double viewWidth) {
    if (viewWidth <= maxMobileWidth) return ViewMode.mobile;
    if (viewWidth <= maxLaptopWidth) return ViewMode.laptop;
    return ViewMode.desktop;
  }

  int getProxiesColumns(double viewWidth, ProxiesLayout proxiesLayout) {
    final columns = max((viewWidth / 300).ceil(), 2);
    return switch (proxiesLayout) {
      ProxiesLayout.tight => columns + 1,
      ProxiesLayout.standard => columns,
      ProxiesLayout.loose => columns - 1,
    };
  }

  int getProfilesColumns(double viewWidth) => max((viewWidth / 320).floor(), 1);

  final _indexPrimary = [
    50,
    100,
    200,
    300,
    400,
    500,
    600,
    700,
    800,
    850,
    900,
  ];

  MaterialColor _createPrimarySwatch(Color color) {
    final swatch = <int, Color>{};
    final a = color.alpha8bit;
    final r = color.red8bit;
    final g = color.green8bit;
    final b = color.blue8bit;
    for (final strength in _indexPrimary) {
      final ds = 0.5 - strength / 1000;
      swatch[strength] = Color.fromARGB(
        a,
        r + ((ds < 0 ? r : (255 - r)) * ds).round(),
        g + ((ds < 0 ? g : (255 - g)) * ds).round(),
        b + ((ds < 0 ? b : (255 - b)) * ds).round(),
      );
    }
    swatch[50] = swatch[50]!.lighten(18);
    swatch[100] = swatch[100]!.lighten(16);
    swatch[200] = swatch[200]!.lighten(14);
    swatch[300] = swatch[300]!.lighten(10);
    swatch[400] = swatch[400]!.lighten(6);
    swatch[700] = swatch[700]!.darken(2);
    swatch[800] = swatch[800]!.darken(3);
    swatch[900] = swatch[900]!.darken(4);
    return MaterialColor(color.value32bit, swatch);
  }

  List<Color> getMaterialColorShades(Color color) {
    final swatch = _createPrimarySwatch(color);
    return <Color>[
      if (swatch[50] != null) swatch[50]!,
      if (swatch[100] != null) swatch[100]!,
      if (swatch[200] != null) swatch[200]!,
      if (swatch[300] != null) swatch[300]!,
      if (swatch[400] != null) swatch[400]!,
      if (swatch[500] != null) swatch[500]!,
      if (swatch[600] != null) swatch[600]!,
      if (swatch[700] != null) swatch[700]!,
      if (swatch[800] != null) swatch[800]!,
      if (swatch[850] != null) swatch[850]!,
      if (swatch[900] != null) swatch[900]!,
    ];
  }

  String getBackupFileName() => "${appName}_backup_${DateTime.now().show}.zip";

  String get logFile => "${appName}_${DateTime.now().show}.log";

  Future<String?> getLocalIpAddress() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
    )
      ..sort((a, b) {
        if (a.isWifi && !b.isWifi) return -1;
        if (!a.isWifi && b.isWifi) return 1;
        if (a.includesIPv4 && !b.includesIPv4) return -1;
        if (!a.includesIPv4 && b.includesIPv4) return 1;
        return 0;
      });
    for (final interface in interfaces) {
      final addresses = interface.addresses;
      if (addresses.isEmpty) {
        continue;
      }
      addresses.sort((a, b) {
        if (a.isIPv4 && !b.isIPv4) return -1;
        if (!a.isIPv4 && b.isIPv4) return 1;
        return 0;
      });
      return addresses.first.address;
    }
    return "";
  }

  SingleActivator controlSingleActivator(LogicalKeyboardKey trigger) {
    final control = Platform.isMacOS ? false : true;
    return SingleActivator(
      trigger,
      control: control,
      meta: !control,
    );
  }

  // dynamic convertYamlNode(dynamic node) {
  //   if (node is YamlMap) {
  //     final map = <String, dynamic>{};
  //     YamlNode? mergeKeyNode;
  //     for (final entry in node.nodes.entries) {
  //       if (entry.key is YamlScalar &&
  //           (entry.key as YamlScalar).value == '<<') {
  //         mergeKeyNode = entry.value;
  //         break;
  //       }
  //     }
  //     if (mergeKeyNode != null) {
  //       final mergeValue = mergeKeyNode.value;
  //       if (mergeValue is YamlMap) {
  //         map.addAll(convertYamlNode(mergeValue) as Map<String, dynamic>);
  //       } else if (mergeValue is YamlList) {
  //         for (final node in mergeValue.nodes) {
  //           if (node.value is YamlMap) {
  //             map.addAll(convertYamlNode(node.value) as Map<String, dynamic>);
  //           }
  //         }
  //       }
  //     }
  //
  //     node.nodes.forEach((key, value) {
  //       String stringKey;
  //       if (key is YamlScalar) {
  //         stringKey = key.value.toString();
  //       } else {
  //         stringKey = key.toString();
  //       }
  //       map[stringKey] = convertYamlNode(value.value);
  //     });
  //     return map;
  //   } else if (node is YamlList) {
  //     final list = <dynamic>[];
  //     for (final item in node.nodes) {
  //       list.add(convertYamlNode(item.value));
  //     }
  //     return list;
  //   } else if (node is YamlScalar) {
  //     return node.value;
  //   }
  //   return node;
  // }

  FutureOr<T> handleWatch<T>(FutureOr<T> Function() function) async {
    if (kDebugMode) {
      final stopwatch = Stopwatch()..start();
      final res = await function();
      stopwatch.stop();
      commonPrint.log('耗时：${stopwatch.elapsedMilliseconds} ms');
      return res;
    }
    return await function();
  }
}

class _ParsedVersion implements Comparable<_ParsedVersion> {
  const _ParsedVersion({
    required this.numbers,
    required this.prerelease,
    required this.build,
  });

  factory _ParsedVersion.parse(String rawVersion) {
    final normalized = rawVersion.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final buildSplit = normalized.split('+');
    final preSplit = buildSplit.first.split('-');
    return _ParsedVersion(
      numbers: preSplit.first
          .split('.')
          .map((part) => int.tryParse(part) ?? 0)
          .toList(growable: false),
      prerelease: preSplit.length > 1 ? preSplit.sublist(1).join('-') : null,
      build: buildSplit.length > 1 ? buildSplit.sublist(1).join('+') : null,
    );
  }

  final List<int> numbers;
  final String? prerelease;
  final String? build;

  @override
  int compareTo(_ParsedVersion other) {
    final numberLength = max(numbers.length, other.numbers.length);
    for (var i = 0; i < numberLength; i++) {
      final current = i < numbers.length ? numbers[i] : 0;
      final next = i < other.numbers.length ? other.numbers[i] : 0;
      if (current != next) {
        return current.compareTo(next);
      }
    }

    final prereleaseCompare = _comparePrerelease(prerelease, other.prerelease);
    if (prereleaseCompare != 0) {
      return prereleaseCompare;
    }

    return _compareBuild(build, other.build);
  }

  static int _comparePrerelease(String? first, String? second) {
    if (first == null && second == null) {
      return 0;
    }
    if (first == null) {
      return 1;
    }
    if (second == null) {
      return -1;
    }

    final firstParts = first.split(RegExp(r'[.-]'));
    final secondParts = second.split(RegExp(r'[.-]'));
    final length = max(firstParts.length, secondParts.length);
    for (var i = 0; i < length; i++) {
      if (i >= firstParts.length) {
        return -1;
      }
      if (i >= secondParts.length) {
        return 1;
      }
      final result = _compareIdentifier(firstParts[i], secondParts[i]);
      if (result != 0) {
        return result;
      }
    }
    return 0;
  }

  static int _compareIdentifier(String first, String second) {
    final firstNumber = int.tryParse(first);
    final secondNumber = int.tryParse(second);
    if (firstNumber != null && secondNumber != null) {
      return firstNumber.compareTo(secondNumber);
    }
    if (firstNumber != null) {
      return -1;
    }
    if (secondNumber != null) {
      return 1;
    }

    final firstMatch = RegExp(r'^([A-Za-z-]+)(\d+)$').firstMatch(first);
    final secondMatch = RegExp(r'^([A-Za-z-]+)(\d+)$').firstMatch(second);
    if (firstMatch != null && secondMatch != null) {
      final prefixCompare =
          firstMatch.group(1)!.compareTo(secondMatch.group(1)!);
      if (prefixCompare != 0) {
        return prefixCompare;
      }
      return int.parse(firstMatch.group(2)!)
          .compareTo(int.parse(secondMatch.group(2)!));
    }

    return first.compareTo(second);
  }

  static int _compareBuild(String? first, String? second) {
    final firstNumber = first == null ? 0 : int.tryParse(first) ?? 0;
    final secondNumber = second == null ? 0 : int.tryParse(second) ?? 0;
    return firstNumber.compareTo(secondNumber);
  }
}

final utils = Utils();
