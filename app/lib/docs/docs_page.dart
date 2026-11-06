import 'dart:async';

import 'package:flutter/material.dart';

import '../runtime.dart';
import '../widgets/common.dart';
import 'inline_markdown.dart';
import 'markdown.dart';

/// Upstream README with heading navigation, search and external links.
class DocsPage extends StatefulWidget {
  const DocsPage({super.key, required this.runtime});

  final AppRuntime runtime;

  @override
  State<DocsPage> createState() => _DocsPageState();
}

class _DocsPageState extends State<DocsPage> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  MarkdownDocument? _document;
  String? _error;
  bool _loading = true;
  String _query = '';
  int _matchCursor = -1;
  List<int> _matches = const [];
  List<GlobalKey> _blockKeys = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _search.addListener(_searchChanged);
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final source = await widget.runtime.loadReadme();
      final document = MarkdownDocument.parse(source);
      if (!mounted) return;
      setState(() {
        _document = document;
        _blockKeys = List.generate(document.blocks.length, (_) => GlobalKey());
        _matches = const [];
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _searchChanged() {
    final query = _search.text.trim();
    final document = _document;
    if (document == null) return;
    final matches = <int>[];
    if (query.isNotEmpty) {
      for (var i = 0; i < document.blocks.length; i++) {
        if (document
            .plainText(document.blocks[i])
            .toLowerCase()
            .contains(query.toLowerCase())) {
          matches.add(i);
        }
      }
    }
    setState(() {
      _query = query;
      _matches = matches;
      _matchCursor = -1;
    });
  }

  void _nextMatch() {
    if (_matches.isEmpty) return;
    setState(() => _matchCursor = (_matchCursor + 1) % _matches.length);
    _jumpTo(_matches[_matchCursor]);
  }

  void _jumpTo(int index) {
    final key = _blockKeys[index];
    final context = key.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        alignment: 0.05,
        duration: const Duration(milliseconds: 220),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: SectionCard(
          title: 'Documentation unavailable',
          child: Text(_error!),
        ),
      );
    }
    final document = _document;
    if (document == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1000;
        final paper = _Paper(
          document: document,
          blockKeys: _blockKeys,
          scroll: _scroll,
          query: _query,
          highlightColor: Theme.of(context).colorScheme.tertiaryContainer,
          onLink: widget.runtime.bridge.openExternal,
        );
        final searchBar = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('docsSearch'),
              controller: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Find in documentation…',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                OutlinedButton(
                  key: const ValueKey('docsNextMatch'),
                  onPressed: _matches.isEmpty ? null : _nextMatch,
                  child: const Text('Next match'),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _query.isEmpty
                        ? ''
                        : _matches.isEmpty
                        ? 'No matches'
                        : '${_matchCursor < 0 ? 1 : _matchCursor + 1}'
                              ' / ${_matches.length}',
                    key: const ValueKey('docsMatchCount'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        );
        if (!wide) {
          return SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionCard(
                  title: 'Documentation',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      searchBar,
                      const SizedBox(height: 12),
                      _HeadingDropdown(
                        headings: document.headings,
                        onSelected: (heading) {
                          final index = document.blocks.indexOf(heading);
                          if (index >= 0) _jumpTo(index);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(height: 900, child: paper),
              ],
            ),
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 238,
                child: SectionCard(
                  title: 'Guide',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      searchBar,
                      const SizedBox(height: 12),
                      for (final heading in document.headings)
                        InkWell(
                          onTap: () {
                            final index = document.blocks.indexOf(heading);
                            if (index >= 0) _jumpTo(index);
                          },
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 5,
                              horizontal: 4,
                            ),
                            child: Text(
                              heading.text,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    fontWeight: heading.level <= 2
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: heading.level <= 2
                                        ? null
                                        : Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                  ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(child: paper),
            ],
          ),
        );
      },
    );
  }
}

class _HeadingDropdown extends StatelessWidget {
  const _HeadingDropdown({required this.headings, required this.onSelected});

  final List<MdHeading> headings;
  final ValueChanged<MdHeading> onSelected;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<MdHeading>(
        isExpanded: true,
        hint: const Text('Jump to a section'),
        items: [
          for (final heading in headings)
            DropdownMenuItem(
              value: heading,
              child: Text(heading.text, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (heading) {
          if (heading != null) onSelected(heading);
        },
      ),
    );
  }
}

class _Paper extends StatelessWidget {
  const _Paper({
    required this.document,
    required this.blockKeys,
    required this.scroll,
    required this.query,
    required this.highlightColor,
    required this.onLink,
  });

  final MarkdownDocument document;
  final List<GlobalKey> blockKeys;
  final ScrollController scroll;
  final String query;
  final Color highlightColor;
  final void Function(String url) onLink;

  @override
  Widget build(BuildContext context) {
    final inline = InlineMarkdown(
      onLink: onLink,
      highlightColor: highlightColor,
      query: query,
    );
    return SectionCard(
      padding: const EdgeInsets.all(6),
      child: SizedBox(
        height: 780,
        child: Scrollbar(
          controller: scroll,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(26, 18, 26, 30),
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < document.blocks.length; i++)
                    KeyedSubtree(
                      key: blockKeys.length > i ? blockKeys[i] : null,
                      child: _BlockView(
                        block: document.blocks[i],
                        inline: inline,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BlockView extends StatelessWidget {
  const _BlockView({required this.block, required this.inline});

  final MdBlock block;
  final InlineMarkdown inline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyMedium?.copyWith(height: 1.55);
    return switch (block) {
      MdHeading(:final level, :final text) => Padding(
        padding: EdgeInsets.only(
          top: level == 1 ? 4 : 22,
          bottom: level <= 2 ? 8 : 5,
        ),
        child: Text.rich(
          TextSpan(
            children: inline.spans(
              text,
              (level == 1
                      ? theme.textTheme.headlineSmall
                      : level == 2
                      ? theme.textTheme.titleLarge
                      : theme.textTheme.titleMedium)
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ),
      MdParagraph(:final text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text.rich(TextSpan(children: inline.spans(text, body))),
      ),
      MdList(:final ordered, :final items) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < items.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 26,
                      child: Text(ordered ? '${i + 1}.' : '•', style: body),
                    ),
                    Expanded(
                      child: Text.rich(
                        TextSpan(children: inline.spans(items[i], body)),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      MdQuote(:final text) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: theme.colorScheme.primary, width: 3),
          ),
          color: theme.colorScheme.surfaceContainerHighest,
        ),
        child: Text.rich(TextSpan(children: inline.spans(text, body))),
      ),
      MdCode(:final code) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF111827),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            code,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12.5,
              color: Color(0xFFD7E3F4),
              height: 1.5,
            ),
          ),
        ),
      ),
      MdRule() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Divider(),
      ),
    };
  }
}
