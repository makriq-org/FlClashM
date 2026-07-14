Map<String, dynamic> copyConfigTree(Map<String, dynamic> source) => {
      for (final entry in source.entries)
        entry.key: _copyConfigValue(entry.value),
    };

dynamic _copyConfigValue(dynamic value) => switch (value) {
      final Map<dynamic, dynamic> map => <String, dynamic>{
          for (final entry in map.entries)
            entry.key.toString(): _copyConfigValue(entry.value),
        },
      final List<dynamic> list => [
          for (final item in list) _copyConfigValue(item),
        ],
      _ => value,
    };
