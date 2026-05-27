import 'package:flutter/material.dart';

class YamlHighlightController extends TextEditingController {
  YamlHighlightController({String? text}) : super(text: text);

  String _searchQuery = '';
  int _currentMatchIndex = -1;
  List<int> _matchPositions = [];

  void setSearch(String query, List<int> positions, int currentIndex) {
    _searchQuery = query;
    _matchPositions = positions;
    _currentMatchIndex = currentIndex;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (text.isEmpty) return TextSpan(style: style, text: '');

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final commentColor = isDark ? Colors.grey : Colors.grey.shade600;
    final keyColor = isDark ? Colors.cyan.shade300 : Colors.indigo;
    final stringColor = isDark ? Colors.green.shade300 : Colors.green.shade800;
    final numberColor = isDark ? Colors.orange.shade300 : Colors.orange.shade800;
    final boolColor = isDark ? Colors.purple.shade200 : Colors.purple;
    final dashColor = isDark ? Colors.red.shade300 : Colors.red.shade700;

    final colors = List<Color?>.filled(text.length, null);
    var offset = 0;
    for (final line in text.split('\n')) {
      if (offset > 0) offset++;
      final lineStart = offset;
      final trimmed = line.trimLeft();

      if (trimmed.startsWith('#')) {
        _fill(colors, lineStart, line.length, commentColor);
      } else if (trimmed.startsWith('- ')) {
        final dashPos = lineStart + line.length - trimmed.length;
        _fill(colors, dashPos, 1, dashColor);
        _fillValue(colors, lineStart + line.length - trimmed.length + 2,
            trimmed.substring(2), stringColor, numberColor, boolColor, commentColor);
      } else {
        final colonIdx = line.indexOf(':');
        if (colonIdx > 0) {
          _fill(colors, lineStart, colonIdx, keyColor);
          _fillValue(colors, lineStart + colonIdx + 1,
              line.substring(colonIdx + 1), stringColor, numberColor, boolColor, commentColor);
        }
      }
      offset = lineStart + line.length;
    }

    final highlightColor = isDark
        ? Colors.yellow.withValues(alpha: 0.4)
        : Colors.yellow.withValues(alpha: 0.6);
    final currentHighlight = isDark
        ? Colors.orange.withValues(alpha: 0.5)
        : Colors.orange.withValues(alpha: 0.4);

    final spans = <TextSpan>[];
    var i = 0;
    while (i < text.length) {
      final searchHit = _searchQuery.isNotEmpty
          ? _matchPositions.indexOf(i)
          : -1;
      if (searchHit >= 0) {
        final len = _searchQuery.length;
        final bg = searchHit == _currentMatchIndex ? currentHighlight : highlightColor;
        spans.add(TextSpan(
          text: text.substring(i, i + len),
          style: style?.copyWith(
            color: colors[i],
            backgroundColor: bg,
            fontWeight: FontWeight.bold,
          ),
        ));
        i += len;
        continue;
      }

      final color = colors[i];
      var end = i + 1;
      while (end < text.length &&
          colors[end] == color &&
          (_searchQuery.isEmpty || !_matchPositions.contains(end))) {
        end++;
      }
      spans.add(TextSpan(
        text: text.substring(i, end),
        style: color != null ? style?.copyWith(color: color) : style,
      ));
      i = end;
    }

    return TextSpan(style: style, children: spans);
  }

  void _fill(List<Color?> colors, int start, int length, Color color) {
    for (var i = start; i < start + length && i < colors.length; i++) {
      colors[i] = color;
    }
  }

  void _fillValue(List<Color?> colors, int start, String val,
      Color stringColor, Color numberColor, Color boolColor, Color commentColor) {
    final commentIdx = val.indexOf(' #');
    final value = commentIdx >= 0 ? val.substring(0, commentIdx) : val;
    final trimmed = value.trim();

    Color? color;
    if (trimmed == 'true' || trimmed == 'false' || trimmed == 'null') {
      color = boolColor;
    } else if (trimmed.isNotEmpty && num.tryParse(trimmed) != null) {
      color = numberColor;
    } else if (trimmed.startsWith('"') || trimmed.startsWith("'")) {
      color = stringColor;
    } else if (trimmed.isNotEmpty) {
      color = stringColor;
    }

    if (color != null) _fill(colors, start, value.length, color);
    if (commentIdx >= 0) {
      _fill(colors, start + commentIdx, val.length - commentIdx, commentColor);
    }
  }
}
