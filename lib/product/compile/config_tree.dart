Map<String, dynamic> copyConfigTree(Map<String, dynamic> source) => {
      for (final entry in source.entries)
        entry.key: _copyConfigValue(entry.value),
    };

Map<String, dynamic> freezeConfigTree(Map<String, dynamic> source) =>
    Map<String, dynamic>.unmodifiable({
      for (final entry in source.entries)
        entry.key: _freezeConfigValue(entry.value),
    });

dynamic _freezeConfigValue(dynamic value) => switch (value) {
      final Map<dynamic, dynamic> map => Map<String, dynamic>.unmodifiable({
          for (final entry in map.entries)
            entry.key.toString(): _freezeConfigValue(entry.value),
        }),
      final List<dynamic> list => List<dynamic>.unmodifiable(
          list.map(_freezeConfigValue),
        ),
      _ => value,
    };

dynamic _copyConfigValue(dynamic value) => switch (value) {
      final Map<dynamic, dynamic> map => <String, dynamic>{
          for (final entry in map.entries)
            entry.key.toString(): _copyConfigValue(entry.value),
        },
      final List<dynamic> list => [
          for (final item in list) _copyConfigValue(item)
        ],
      _ => value,
    };
