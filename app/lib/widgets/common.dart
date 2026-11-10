import 'package:flutter/material.dart';

/// A bordered Material 3 card with an optional heading row.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    this.number,
    this.trailing,
    this.child,
    this.padding = const EdgeInsets.all(18),
  });

  final String? title;
  final String? number;
  final Widget? trailing;
  final Widget? child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      semanticContainer: false,
      elevation: 0,
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null) ...[
              Row(
                children: [
                  if (number != null) ...[
                    Text(
                      number!,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(title!, style: theme.textTheme.titleMedium),
                  ),
                  ?trailing,
                ],
              ),
              const SizedBox(height: 12),
            ],
            ?child,
          ],
        ),
      ),
    );
  }
}

/// The small uppercase caption above a form control.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: theme.textTheme.labelSmall?.copyWith(
            letterSpacing: 1.1,
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}

/// A hint line under a card or control.
class HintText extends StatelessWidget {
  const HintText(this.text, {super.key, this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: error
            ? theme.colorScheme.error
            : theme.colorScheme.onSurfaceVariant,
        height: 1.4,
      ),
    );
  }
}

/// A compact labelled value for summary cards.
class LabeledValue extends StatelessWidget {
  const LabeledValue({
    super.key,
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontFamily: monospace ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The OS badge in the Package configuration card.
class OsBadge extends StatelessWidget {
  const OsBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('osBadge'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

/// A progress bar row for one byte stream.
class ByteProgress extends StatelessWidget {
  const ByteProgress({
    super.key,
    required this.label,
    required this.done,
    required this.total,
    this.detail,
  });

  final String label;
  final int done;
  final int total;

  /// A second line under the bar, for example the transfer rate.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = total > 0 ? (done / total).clamp(0.0, 1.0) : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(value ?? 0) * 100 ~/ 1}%',
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
          const SizedBox(height: 3),
          LinearProgressIndicator(value: value, minHeight: 5),
          if (detail != null) ...[
            const SizedBox(height: 3),
            Text(detail!, style: theme.textTheme.labelSmall),
          ],
        ],
      ),
    );
  }
}
