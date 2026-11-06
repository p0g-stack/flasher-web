/// A small Markdown reader for the upstream README.
///
/// The app renders headings, paragraphs, lists, quotes, fenced code and links;
/// it is deliberately not a full CommonMark implementation.
library;

sealed class MdBlock {
  const MdBlock();
}

final class MdHeading extends MdBlock {
  const MdHeading(this.level, this.text);

  final int level;
  final String text;

  String get anchor => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w -]'), '')
      .replaceAll(' ', '-');
}

final class MdParagraph extends MdBlock {
  const MdParagraph(this.text);

  final String text;
}

final class MdList extends MdBlock {
  const MdList({required this.ordered, required this.items});

  final bool ordered;
  final List<String> items;
}

final class MdQuote extends MdBlock {
  const MdQuote(this.text);

  final String text;
}

final class MdCode extends MdBlock {
  const MdCode(this.code, {this.language});

  final String code;
  final String? language;
}

final class MdRule extends MdBlock {
  const MdRule();
}

final class MarkdownDocument {
  const MarkdownDocument(this.blocks);

  factory MarkdownDocument.parse(String source) {
    final blocks = <MdBlock>[];
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    var index = 0;
    while (index < lines.length) {
      final line = lines[index];
      if (line.trim().isEmpty) {
        index++;
        continue;
      }
      final fence = RegExp(r'^```(.*)$').firstMatch(line);
      if (fence != null) {
        final language = fence.group(1)!.trim();
        final code = <String>[];
        index++;
        while (index < lines.length && !lines[index].startsWith('```')) {
          code.add(lines[index]);
          index++;
        }
        if (index < lines.length) index++;
        blocks.add(
          MdCode(code.join('\n'), language: language.isEmpty ? null : language),
        );
        continue;
      }
      final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
      if (heading != null) {
        blocks.add(
          MdHeading(heading.group(1)!.length, heading.group(2)!.trim()),
        );
        index++;
        continue;
      }
      if (RegExp(r'^\s*(---+|\*\*\*+)\s*$').hasMatch(line)) {
        blocks.add(const MdRule());
        index++;
        continue;
      }
      if (RegExp(r'^\s*>\s?').hasMatch(line)) {
        final quote = <String>[];
        while (index < lines.length &&
            RegExp(r'^\s*>\s?').hasMatch(lines[index])) {
          quote.add(lines[index].replaceFirst(RegExp(r'^\s*>\s?'), ''));
          index++;
        }
        blocks.add(MdQuote(quote.join(' ')));
        continue;
      }
      final bullet = RegExp(r'^\s*[-*+]\s+');
      if (bullet.hasMatch(line)) {
        final items = <String>[];
        while (index < lines.length && bullet.hasMatch(lines[index])) {
          items.add(lines[index].replaceFirst(bullet, '').trim());
          index++;
        }
        blocks.add(MdList(ordered: false, items: items));
        continue;
      }
      final ordered = RegExp(r'^\s*\d+[.)]\s+');
      if (ordered.hasMatch(line)) {
        final items = <String>[];
        while (index < lines.length && ordered.hasMatch(lines[index])) {
          items.add(lines[index].replaceFirst(ordered, '').trim());
          index++;
        }
        blocks.add(MdList(ordered: true, items: items));
        continue;
      }
      final paragraph = <String>[line.trim()];
      index++;
      while (index < lines.length) {
        final next = lines[index];
        if (next.trim().isEmpty ||
            next.startsWith('```') ||
            RegExp(r'^(#{1,6})\s+').hasMatch(next) ||
            RegExp(r'^\s*[-*+]\s+').hasMatch(next) ||
            RegExp(r'^\s*\d+[.)]\s+').hasMatch(next) ||
            RegExp(r'^\s*>\s?').hasMatch(next) ||
            RegExp(r'^\s*(---+|\*\*\*+)\s*$').hasMatch(next)) {
          break;
        }
        paragraph.add(next.trim());
        index++;
      }
      blocks.add(MdParagraph(paragraph.join(' ')));
    }
    return MarkdownDocument(blocks);
  }

  final List<MdBlock> blocks;

  List<MdHeading> get headings => [
    for (final block in blocks)
      if (block is MdHeading) block,
  ];

  String plainText(MdBlock block) => switch (block) {
    MdHeading(:final text) => text,
    MdParagraph(:final text) => text,
    MdQuote(:final text) => text,
    MdCode(:final code) => code,
    MdList(:final items) => items.join(' '),
    MdRule() => '',
  };
}
