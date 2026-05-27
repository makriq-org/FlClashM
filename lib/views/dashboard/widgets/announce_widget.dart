import 'dart:convert';
import 'package:emoji_regex/emoji_regex.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AnnounceWidget extends ConsumerWidget {
  const AnnounceWidget({super.key});

  List<InlineSpan> _emojiAware(String text, TextStyle? style) {
    final spans = <InlineSpan>[];
    final emoji = emojiRegex();
    var last = 0;
    for (final m in emoji.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start), style: style));
      }
      spans.add(TextSpan(
        text: m.group(0),
        style: style?.copyWith(fontFamily: FontFamily.twEmoji.value),
      ));
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: style));
    }
    return spans;
  }

  List<InlineSpan> _buildTextSpans(BuildContext context, String text) {
    final urlPattern = RegExp(r'https?://[^\s]+', caseSensitive: false);
    final baseStyle = Theme.of(context).textTheme.bodyLarge;
    final linkStyle = baseStyle?.copyWith(
      color: Theme.of(context).colorScheme.primary,
    );

    final spans = <InlineSpan>[];
    var lastIndex = 0;

    for (final match in urlPattern.allMatches(text)) {
      if (match.start > lastIndex) {
        spans.addAll(_emojiAware(text.substring(lastIndex, match.start), baseStyle));
      }
      final url = match.group(0)!;
      spans.add(TextSpan(
        text: url,
        style: linkStyle,
        recognizer: TapGestureRecognizer()
          ..onTap = () => globalState.openUrl(url),
      ));
      lastIndex = match.end;
    }

    if (lastIndex < text.length) {
      spans.addAll(_emojiAware(text.substring(lastIndex), baseStyle));
    }

    return spans;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider);

    if (profile == null) {
      return const SizedBox.shrink();
    }

    final encodedText = profile.providerHeaders['announce'];
    String? announceText;

    if (encodedText != null && encodedText.isNotEmpty) {
      var textToDecode = encodedText;
      if (encodedText.startsWith('base64:')) {
        textToDecode = encodedText.substring(7);
      }
      try {
        final normalized = base64.normalize(textToDecode);
        announceText = utf8.decode(base64.decode(normalized));
      } catch (e) {
        announceText = encodedText;
      }
    }

    if (announceText == null || announceText.isEmpty) {
      return const SizedBox.shrink();
    }

    return CommonCard(
      onPressed: null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        child: Align(
          alignment: Alignment.topLeft,
          child: RichText(
            text: TextSpan(
              children: _buildTextSpans(context, announceText),
            ),
          ),
        ),
      ),
    );
  }
}
