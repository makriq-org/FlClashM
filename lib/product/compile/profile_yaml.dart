import 'dart:io';

import 'package:yaml/yaml.dart';

Map<String, dynamic> loadProfileConfigFromString(String text) {
  final yaml = loadYaml(text);
  if (yaml is! Map && yaml is! YamlMap) {
    throw const FormatException('Profile root must be a YAML map.');
  }
  return materializeStringKeyedMap(yaml);
}

Future<Map<String, dynamic>> loadProfileConfigFromFile(String filePath) async {
  final file = File(filePath);
  final text = await file.readAsString();
  return loadProfileConfigFromString(text);
}

Map<String, dynamic> materializeStringKeyedMap(dynamic value) {
  if (value is! Map && value is! YamlMap) {
    return <String, dynamic>{};
  }
  final result = <String, dynamic>{};

  for (final entry in value.entries) {
    if (entry.key.toString() != '<<') {
      continue;
    }
    for (final mergedMap in _materializeYamlMerge(entry.value)) {
      result.addAll(mergedMap);
    }
  }

  for (final entry in value.entries) {
    if (entry.key.toString() == '<<') {
      continue;
    }
    result[entry.key.toString()] = materializeYamlValue(entry.value);
  }
  return result;
}

List<Map<String, dynamic>> _materializeYamlMerge(dynamic value) {
  if (value is Map || value is YamlMap) {
    return [materializeStringKeyedMap(value)];
  }
  if (value is List || value is YamlList) {
    return value
        .where((entry) => entry is Map || entry is YamlMap)
        .map(materializeStringKeyedMap)
        .toList();
  }
  return const [];
}

dynamic materializeYamlValue(dynamic value) {
  if (value is Map || value is YamlMap) {
    return materializeStringKeyedMap(value);
  }
  if (value is List || value is YamlList) {
    return value.map(materializeYamlValue).toList();
  }
  return value;
}
