import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'byedpi_cli_validator.dart';
import 'stormdns_resolver_sources.dart';

const byedpiMaxRemoteStrategyLists = 32;
const byedpiMaxStrategies = 4096;

sealed class ByedpiStrategySource {
  const ByedpiStrategySource();
}

class ByedpiBuiltinStrategySource extends ByedpiStrategySource {
  const ByedpiBuiltinStrategySource(this.name);
  final String name;
}

class ByedpiInlineStrategySource extends ByedpiStrategySource {
  const ByedpiInlineStrategySource(this.strategy);
  final String strategy;
}

class ByedpiRemoteStrategySource extends ByedpiStrategySource {
  const ByedpiRemoteStrategySource(this.url);
  final Uri url;
}

@immutable
class ByedpiRemoteStrategyList {
  const ByedpiRemoteStrategyList({
    required this.strategies,
    required this.fetchedAt,
  });
  final List<String> strategies;
  final DateTime fetchedAt;
}

class ByedpiStrategySourceParser {
  const ByedpiStrategySourceParser({
    this.cliValidator = const ByedpiCliValidator(),
  });

  final ByedpiCliValidator cliValidator;

  List<ByedpiStrategySource> parse(Object? value) {
    final values = value ?? const ['builtin:byebyeedpi'];
    if (values is! List) {
      throw const FormatException('byedpi `strategies` must be a list.');
    }
    final result = <ByedpiStrategySource>[];
    for (var index = 0; index < values.length; index++) {
      final item = values[index];
      if (item is! String || item.trim().isEmpty || item != item.trim()) {
        throw FormatException(
          'byedpi `strategies[$index]` must be a non-empty trimmed string.',
        );
      }
      if (item.startsWith('builtin:')) {
        final name = item.substring('builtin:'.length);
        if (name != 'byebyeedpi') {
          throw FormatException(
            'byedpi `strategies[$index]` names unknown builtin `$name`.',
          );
        }
        result.add(ByedpiBuiltinStrategySource(name));
      } else if (item.toLowerCase().startsWith('https://')) {
        final uri = Uri.tryParse(item);
        if (uri == null || !isSafeResolverListUrl(uri)) {
          throw FormatException(
            'byedpi `strategies[$index]` must use a public HTTPS URL.',
          );
        }
        result.add(ByedpiRemoteStrategySource(uri));
      } else {
        cliValidator.validate(
          item,
          path: 'byedpi.strategies[$index]',
          context: ByedpiCliContext.strategy,
        );
        result.add(ByedpiInlineStrategySource(item));
      }
    }
    return List.unmodifiable(result);
  }

  List<Uri> remoteUrls(Object? value) => [
        for (final source in parse(value))
          if (source is ByedpiRemoteStrategySource) source.url,
      ];

  List<String> parseRemoteBody(String body, Uri url) {
    final result = <String>[];
    for (final line in const LineSplitter().convert(body)) {
      final value = line.trim();
      if (value.isEmpty || value.startsWith('#')) continue;
      cliValidator.validate(
        value,
        path: 'byedpi remote strategy list `$url`',
        context: ByedpiCliContext.strategy,
      );
      result.add(value);
      if (result.length >= byedpiMaxStrategies) break;
    }
    return List.unmodifiable(result);
  }
}

List<String> expandByedpiStrategies({
  required List<ByedpiStrategySource> sources,
  required Map<Uri, ByedpiRemoteStrategyList> remoteLists,
}) {
  final result = <String>[];
  final seen = <String>{};
  for (final source in sources) {
    final values = switch (source) {
      ByedpiBuiltinStrategySource(:final name) => ['builtin:$name'],
      ByedpiInlineStrategySource(:final strategy) => [strategy],
      ByedpiRemoteStrategySource(:final url) =>
        remoteLists[url]?.strategies ?? const <String>[],
    };
    for (final value in values) {
      if (seen.add(value)) result.add(value);
      if (result.length >= byedpiMaxStrategies) {
        return List.unmodifiable(result);
      }
    }
  }
  return List.unmodifiable(result);
}
