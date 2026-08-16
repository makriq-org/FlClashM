import 'dart:convert';

void yamlDump(StringBuffer buf, dynamic value, int indent) {
  final prefix = '  ' * indent;
  if (value is Map) {
    if (value.isEmpty) {
      buf.writeln('$prefix{}');
      return;
    }
    for (final entry in value.entries) {
      final k = _yamlKey(entry.key.toString());
      final v = entry.value;
      if (v is Map || v is List) {
        if (v.isEmpty) {
          buf.writeln('$prefix$k: ${v is Map ? '{}' : '[]'}');
        } else {
          buf.writeln('$prefix$k:');
          yamlDump(buf, v, indent + 1);
        }
      } else {
        buf.writeln('$prefix$k: ${_yamlScalar(v)}');
      }
    }
  } else if (value is List) {
    if (value.isEmpty) {
      buf.writeln('$prefix[]');
      return;
    }
    for (final item in value) {
      if (item is Map || item is List) {
        if (item.isEmpty) {
          buf.writeln('$prefix- ${item is Map ? '{}' : '[]'}');
        } else {
          buf.writeln('$prefix-');
          yamlDump(buf, item, indent + 1);
        }
      } else {
        buf.writeln('$prefix- ${_yamlScalar(item)}');
      }
    }
  } else {
    buf.writeln('$prefix${_yamlScalar(value)}');
  }
}

String _yamlScalar(dynamic v) {
  if (v == null) return 'null';
  if (v is bool) return v.toString();
  if (v is num) {
    if (v is double && v.isNaN) return '.nan';
    if (v == double.infinity) return '.inf';
    if (v == double.negativeInfinity) return '-.inf';
    return v.toString();
  }
  return jsonEncode(v.toString());
}

String _yamlKey(String value) {
  final isPlain = RegExp(r'^[A-Za-z_][A-Za-z0-9_-]*$').hasMatch(value);
  const ambiguousPlainValues = {
    'null',
    'true',
    'false',
    'yes',
    'no',
    'on',
    'off',
  };
  if (isPlain && !ambiguousPlainValues.contains(value.toLowerCase())) {
    return value;
  }
  return jsonEncode(value);
}
