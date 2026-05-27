void yamlDump(StringBuffer buf, dynamic value, int indent) {
  final prefix = '  ' * indent;
  if (value is Map) {
    for (final entry in value.entries) {
      final k = entry.key;
      final v = entry.value;
      if (v is Map || v is List) {
        buf.writeln('$prefix$k:');
        yamlDump(buf, v, indent + 1);
      } else {
        buf.writeln('$prefix$k: ${_yamlScalar(v)}');
      }
    }
  } else if (value is List) {
    for (final item in value) {
      if (item is Map || item is List) {
        buf.writeln('$prefix-');
        yamlDump(buf, item, indent + 1);
      } else {
        buf.writeln('$prefix- ${_yamlScalar(item)}');
      }
    }
  }
}

String _yamlScalar(dynamic v) {
  if (v == null) return 'null';
  if (v is bool) return v.toString();
  if (v is num) return v.toString();
  final s = v.toString();
  if (s.contains(':') || s.contains('#') || s.contains("'") ||
      s.contains('"') || s.contains('\n') || s.isEmpty) {
    return '"${s.replaceAll('"', r'\"')}"';
  }
  return s;
}
