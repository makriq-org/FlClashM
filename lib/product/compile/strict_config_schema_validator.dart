import 'dart:math' as math;

import 'built_in_proxy_schema.dart';

class StrictConfigSchemaValidator {
  const StrictConfigSchemaValidator();

  void validate(
    Map<String, dynamic> config, {
    required BuiltInProxySchema schema,
    String? mode,
  }) {
    final rootPath = schema.fields.first.path.split('.').first;
    final fieldsByPath = <String, BuiltInProxyFieldSchema>{
      for (final field in schema.fields) field.path: field,
    };
    _validateObject(
      config,
      schema: schema,
      fieldsByPath: fieldsByPath,
      canonicalPath: rootPath,
      actualPath: rootPath,
      mode: mode,
    );
  }

  void _validateObject(
    Map<dynamic, dynamic> value, {
    required BuiltInProxySchema schema,
    required Map<String, BuiltInProxyFieldSchema> fieldsByPath,
    required String canonicalPath,
    required String actualPath,
    required String? mode,
  }) {
    final directFields = _directFields(schema.fields, canonicalPath);
    final fieldNames = directFields.keys.toList(growable: false);

    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw FormatException('$actualPath has a non-string field name.');
      }
      final key = entry.key as String;
      final field = directFields[key];
      final fieldPath = '$actualPath.$key';
      if (field == null) {
        final suggestion = _nearest(key, fieldNames);
        throw FormatException(
          '$fieldPath is unknown; unknown or forbidden fields are not supported.'
          '${suggestion == null ? '' : ' Did you mean `$suggestion`?'}',
        );
      }
      if (field.forbiddenReason case final reason?) {
        throw FormatException(
          '$fieldPath is forbidden: $reason; '
          'unknown or forbidden fields are not supported.',
        );
      }
      if (field.modes.isNotEmpty && !field.modes.contains(mode)) {
        throw FormatException(
          '$fieldPath is not available in mode `${mode ?? 'unspecified'}`; '
          'allowed modes: ${field.modes.join(', ')}.',
        );
      }

      _validateValue(entry.value, field: field, actualPath: fieldPath);
      if (entry.value is Map &&
          schema.fields.any(
              (candidate) => candidate.path.startsWith('${field.path}.'))) {
        _validateObject(
          entry.value as Map,
          schema: schema,
          fieldsByPath: fieldsByPath,
          canonicalPath: field.path,
          actualPath: fieldPath,
          mode: mode,
        );
      } else if (entry.value is List) {
        _validateList(
          entry.value as List,
          schema: schema,
          fieldsByPath: fieldsByPath,
          canonicalPath: field.path,
          actualPath: fieldPath,
          mode: mode,
        );
      }
    }

    for (final entry in directFields.entries) {
      final field = entry.value;
      if (!field.required ||
          field.forbiddenReason != null ||
          field.modes.isNotEmpty && !field.modes.contains(mode)) {
        continue;
      }
      if (!value.containsKey(entry.key)) {
        throw FormatException('$actualPath.${entry.key} is required.');
      }
    }
  }

  void _validateList(
    List<dynamic> value, {
    required BuiltInProxySchema schema,
    required Map<String, BuiltInProxyFieldSchema> fieldsByPath,
    required String canonicalPath,
    required String actualPath,
    required String? mode,
  }) {
    final itemSchema = fieldsByPath['$canonicalPath[]'];
    if (itemSchema == null) {
      return;
    }
    for (var index = 0; index < value.length; index++) {
      final itemPath = '$actualPath[$index]';
      _validateValue(value[index], field: itemSchema, actualPath: itemPath);
      if (itemSchema.type == ConfigValueType.object) {
        _validateObject(
          value[index] as Map,
          schema: schema,
          fieldsByPath: fieldsByPath,
          canonicalPath: itemSchema.path,
          actualPath: itemPath,
          mode: mode,
        );
      }
    }
  }

  Map<String, BuiltInProxyFieldSchema> _directFields(
    List<BuiltInProxyFieldSchema> fields,
    String parentPath,
  ) {
    final prefix = '$parentPath.';
    final result = <String, BuiltInProxyFieldSchema>{};
    for (final field in fields) {
      if (!field.path.startsWith(prefix)) continue;
      final remainder = field.path.substring(prefix.length);
      if (remainder.isEmpty || remainder.contains('.')) continue;
      if (remainder.endsWith('[]')) continue;
      result[remainder] = field;
    }
    return result;
  }

  void _validateValue(
    Object? value, {
    required BuiltInProxyFieldSchema field,
    required String actualPath,
  }) {
    final matchesType = <ConfigValueType>{
      field.type,
      ...field.additionalTypes,
    }.any((type) => _matchesType(value, type));
    if (!matchesType) {
      throw FormatException(
        '$actualPath must be ${_typeLabel(field.type)}; got ${value.runtimeType}.',
      );
    }
    if (field.allowedValues.isNotEmpty &&
        !field.allowedValues.contains(value)) {
      throw FormatException(
        '$actualPath must be one of: ${field.allowedValues.join(', ')}.',
      );
    }
    if (value is num) {
      if (!value.isFinite) {
        throw FormatException('$actualPath must be finite.');
      }
      final minimum = field.range.minimum;
      final maximum = field.range.maximum;
      final belowMinimum = minimum != null &&
          (value < minimum || field.range.exclusiveMinimum && value == minimum);
      final aboveMaximum = maximum != null && value > maximum;
      if (belowMinimum || aboveMaximum) {
        final lowerBound = minimum == null
            ? '-infinity'
            : '${field.range.exclusiveMinimum ? '(' : '['}$minimum';
        final upperBound = maximum == null ? 'infinity' : '$maximum]';
        throw FormatException(
          '$actualPath must be in the range $lowerBound..$upperBound.',
        );
      }
    }
  }

  bool _matchesType(Object? value, ConfigValueType type) => switch (type) {
        ConfigValueType.string => value is String,
        ConfigValueType.boolean => value is bool,
        ConfigValueType.integer => value is int,
        ConfigValueType.number => value is num && value.isFinite,
        ConfigValueType.object => value is Map,
        ConfigValueType.list => value is List,
      };

  String _typeLabel(ConfigValueType type) => switch (type) {
        ConfigValueType.string => 'a string',
        ConfigValueType.boolean => 'a boolean',
        ConfigValueType.integer => 'an integer',
        ConfigValueType.number => 'a finite number',
        ConfigValueType.object => 'a map',
        ConfigValueType.list => 'a list',
      };

  String? _nearest(String value, List<String> candidates) {
    if (candidates.isEmpty) return null;
    return candidates.reduce(
      (best, candidate) => _distance(value, candidate) < _distance(value, best)
          ? candidate
          : best,
    );
  }

  int _distance(String left, String right) {
    var previous = List<int>.generate(right.length + 1, (index) => index);
    for (var i = 0; i < left.length; i++) {
      final current = <int>[i + 1];
      for (var j = 0; j < right.length; j++) {
        current.add(
          math.min(
            math.min(current[j] + 1, previous[j + 1] + 1),
            previous[j] + (left.codeUnitAt(i) == right.codeUnitAt(j) ? 0 : 1),
          ),
        );
      }
      previous = current;
    }
    return previous.last;
  }
}
