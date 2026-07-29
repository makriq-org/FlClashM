const diagnosticEntryByteLimit = 16 * 1024;
const diagnosticTruncationMarker = '…<truncated>';

String truncateDiagnosticUtf8(
  String value, {
  int maxBytes = diagnosticEntryByteLimit,
  String suffix = diagnosticTruncationMarker,
}) {
  if (maxBytes < 0) {
    throw RangeError.range(maxBytes, 0, null, 'maxBytes');
  }
  if (value.isEmpty || maxBytes == 0) {
    return value.isEmpty ? value : '';
  }

  final suffixBytes = diagnosticUtf8Length(suffix);
  final usableSuffix = suffixBytes <= maxBytes ? suffix : '';
  final contentLimit = maxBytes - (usableSuffix.isEmpty ? 0 : suffixBytes);
  var index = 0;
  var bytes = 0;
  var contentEnd = 0;

  while (index < value.length) {
    final first = value.codeUnitAt(index);
    final isSurrogatePair = first >= 0xd800 &&
        first <= 0xdbff &&
        index + 1 < value.length &&
        value.codeUnitAt(index + 1) >= 0xdc00 &&
        value.codeUnitAt(index + 1) <= 0xdfff;
    final codePoint = isSurrogatePair
        ? 0x10000 +
            ((first - 0xd800) << 10) +
            (value.codeUnitAt(index + 1) - 0xdc00)
        : first;
    final codePointBytes = _utf8CodePointLength(codePoint);
    if (bytes + codePointBytes > maxBytes) break;
    bytes += codePointBytes;
    index += isSurrogatePair ? 2 : 1;
    if (bytes <= contentLimit) contentEnd = index;
  }

  if (index == value.length) return value;
  if (usableSuffix.isEmpty) return value.substring(0, index);
  return '${value.substring(0, contentEnd)}$usableSuffix';
}

int diagnosticUtf8Length(String value) {
  var result = 0;
  var index = 0;
  while (index < value.length) {
    final first = value.codeUnitAt(index);
    final isSurrogatePair = first >= 0xd800 &&
        first <= 0xdbff &&
        index + 1 < value.length &&
        value.codeUnitAt(index + 1) >= 0xdc00 &&
        value.codeUnitAt(index + 1) <= 0xdfff;
    final codePoint = isSurrogatePair
        ? 0x10000 +
            ((first - 0xd800) << 10) +
            (value.codeUnitAt(index + 1) - 0xdc00)
        : first;
    result += _utf8CodePointLength(codePoint);
    index += isSurrogatePair ? 2 : 1;
  }
  return result;
}

int _utf8CodePointLength(int codePoint) {
  if (codePoint <= 0x7f) return 1;
  if (codePoint <= 0x7ff) return 2;
  if (codePoint <= 0xffff) return 3;
  return 4;
}
