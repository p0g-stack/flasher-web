import 'package:flutter/material.dart';

/// Turns one inline Markdown string into styled spans.
///
/// Links become small inline widgets that open through [onLink] in a new tab;
/// a search [query] is highlighted in every text span.
final class InlineMarkdown {
  InlineMarkdown({
    required this.onLink,
    required this.highlightColor,
    this.query = '',
  });

  final void Function(String url) onLink;
  final Color highlightColor;
  final String query;

  static final _token = RegExp(
    r'(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)]+\)|https?://[^\s)]+)',
  );

  List<InlineSpan> spans(String text, TextStyle? style) {
    final result = <InlineSpan>[];
    var index = 0;
    for (final match in _token.allMatches(text)) {
      if (match.start > index) {
        result.addAll(_plain(text.substring(index, match.start), style));
      }
      final token = match.group(0)!;
      if (token.startsWith('**') && token.endsWith('**')) {
        result.addAll(
          _plain(
            token.substring(2, token.length - 2),
            style?.copyWith(fontWeight: FontWeight.w700),
          ),
        );
      } else if (token.startsWith('`') && token.endsWith('`')) {
        result.addAll(
          _plain(
            token.substring(1, token.length - 1),
            style?.copyWith(
              fontFamily: 'monospace',
              backgroundColor: highlightColor.withValues(alpha: 0.15),
            ),
          ),
        );
      } else if (token.startsWith('[')) {
        final split = token.indexOf('](');
        if (split > 0) {
          final label = token.substring(1, split);
          final url = token.substring(split + 2, token.length - 1);
          final uri = Uri.tryParse(url);
          final external =
              uri != null &&
              (uri.scheme.toLowerCase() == 'http' ||
                  uri.scheme.toLowerCase() == 'https');
          if (!external) {
            result.addAll(_plain(label, style));
          } else {
            result.add(
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: GestureDetector(
                  onTap: () => onLink(url),
                  child: Text(
                    label,
                    style: style?.copyWith(
                      color: const Color(0xFF3268D9),
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
            );
          }
        } else {
          result.addAll(_plain(token, style));
        }
      } else {
        result.addAll(_plain(token, style));
      }
      index = match.end;
    }
    if (index < text.length) {
      result.addAll(_plain(text.substring(index), style));
    }
    return result;
  }

  List<InlineSpan> _plain(String text, TextStyle? style) {
    if (query.isEmpty || !text.toLowerCase().contains(query.toLowerCase())) {
      return [TextSpan(text: text, style: style)];
    }
    final spans = <InlineSpan>[];
    final lower = text.toLowerCase();
    final needle = query.toLowerCase();
    var start = 0;
    while (true) {
      final at = lower.indexOf(needle, start);
      if (at < 0) break;
      if (at > start) {
        spans.add(TextSpan(text: text.substring(start, at), style: style));
      }
      spans.add(
        TextSpan(
          text: text.substring(at, at + query.length),
          style: style?.copyWith(
            backgroundColor: highlightColor,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      start = at + query.length;
    }
    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start), style: style));
    }
    return spans;
  }
}
