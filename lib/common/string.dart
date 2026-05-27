import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'print.dart';

extension StringExtension on String {
  bool get isUrl => RegExp(r'^(http|https|ftp)://').hasMatch(this);

  String get normalizeUrlCredentials {
    final match = RegExp(r'^(https?://)([^/]+)@([^/].*)$').firstMatch(this);
    if (match == null) return this;
    final scheme = match.group(1)!;
    final userinfo = match.group(2)!;
    final hostAndPath = match.group(3)!;
    final encoded = userinfo.replaceAll('@', '%40');
    return '$scheme$encoded@$hostAndPath';
  }

  dynamic get splitByMultipleSeparators {
    final parts =
        split(RegExp(r'[, ;]+')).where((part) => part.isNotEmpty).toList();

    return parts.length > 1 ? parts : this;
  }

  int compareToLower(String other) => toLowerCase().compareTo(
      other.toLowerCase(),
    );

  List<int> get encodeUtf16LeWithBom {
    final byteData = ByteData(length * 2);
    final bom = [0xFF, 0xFE];
    for (var i = 0; i < length; i++) {
      final charCode = codeUnitAt(i);
      byteData.setUint16(i * 2, charCode, Endian.little);
    }
    return bom + byteData.buffer.asUint8List();
  }

  Uint8List? get getBase64 {
    final regExp = RegExp(r'base64,(.*)');
    final match = regExp.firstMatch(this);
    final realValue = match?.group(1) ?? '';
    if (realValue.isEmpty) {
      return null;
    }
    try {
      return base64.decode(realValue);
    } catch (e) {
      return null;
    }
  }

  bool get isSvg => endsWith(".svg");

  bool get isRegex {
    try {
      RegExp(this);
      return true;
    } catch (e) {
      commonPrint.log(e.toString());
      return false;
    }
  }

  String toMd5() {
    final bytes = utf8.encode(this);
    return md5.convert(bytes).toString();
  }
}

extension StringExtensionSafe on String? {
  String getSafeValue(String defaultValue) {
    if (this == null || this!.isEmpty) {
      return defaultValue;
    }
    return this!;
  }
}
