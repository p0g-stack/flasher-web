import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'build_controller.dart';

/// Build output: steps, elapsed time, live log, byte progress and the result.
class BuildOutputPage extends StatefulWidget {
  const BuildOutputPage({
    super.key,
    required this.controller,
    required this.onBack,
  });

  final BuildController controller;
  final VoidCallback onBack;

  @override
  State<BuildOutputPage> createState() => _BuildOutputPageState();
}

class _BuildOutputPageState extends State<BuildOutputPage> {
  final _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scrollLog);
  }

  @override
  void didUpdateWidget(BuildOutputPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_scrollLog);
      widget.controller.addListener(_scrollLog);
    }
  }

  void _scrollLog() {
    if (!_logScroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_logScroll.hasClients) return;
      _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scrollLog);
    _logScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1100;
            final console = _ConsoleCard(
              controller: controller,
              scrollController: _logScroll,
            );
            final side = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SummaryCard(controller: controller),
                const SizedBox(height: 16),
                if (controller.hasResult) _ResultCard(controller: controller),
              ],
            );
            return SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatusCard(controller: controller),
                  const SizedBox(height: 16),
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: console),
                        const SizedBox(width: 20),
                        SizedBox(width: 320, child: side),
                      ],
                    )
                  else ...[
                    console,
                    const SizedBox(height: 16),
                    side,
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        key: const ValueKey('backToSetup'),
                        onPressed: widget.onBack,
                        icon: const Icon(Icons.arrow_back, size: 18),
                        label: const Text('Back to setup'),
                      ),
                      const Spacer(),
                      if (controller.running)
                        FilledButton.tonalIcon(
                          key: const ValueKey('cancelBuild'),
                          onPressed: controller.cancel,
                          icon: const Icon(Icons.stop, size: 18),
                          label: const Text('Cancel build'),
                        ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller});

  final BuildController controller;

  String get _title => switch (controller.phase) {
    BuildPhase.idle => 'Ready when you are',
    BuildPhase.running =>
      controller.stepTitle.isEmpty
          ? 'Preparing your build'
          : controller.stepTitle,
    BuildPhase.succeeded => 'Package complete · ready in your output folder',
    BuildPhase.failed => 'Build failed · see output below',
    BuildPhase.canceled => 'Build cancelled · output cleaned',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labels = controller.stepLabels;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _title,
                  key: const ValueKey('buildStatus'),
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Text(
                controller.phase == BuildPhase.idle
                    ? 'No build running'
                    : controller.elapsedText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: switch (controller.phase) {
              BuildPhase.idle => 0,
              BuildPhase.running =>
                controller.stepIndex / controller.totalSteps,
              BuildPhase.succeeded => 1,
              BuildPhase.failed || BuildPhase.canceled => 0,
            },
            minHeight: 6,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              for (var i = 0; i < labels.length; i++)
                _StepPill(
                  label: labels[i],
                  active: controller.stepIndex - 1 == i,
                  done:
                      controller.stepIndex - 1 > i ||
                      controller.phase == BuildPhase.succeeded,
                ),
            ],
          ),
          if (controller.error != null) ...[
            const SizedBox(height: 10),
            HintText(controller.error!, error: true),
          ],
        ],
      ),
    );
  }
}

class _StepPill extends StatelessWidget {
  const _StepPill({
    required this.label,
    required this.active,
    required this.done,
  });

  final String label;
  final bool active;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = active
        ? theme.colorScheme.primary
        : done
        ? theme.colorScheme.secondaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final foreground = active
        ? theme.colorScheme.onPrimary
        : done
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}

class _ConsoleCard extends StatelessWidget {
  const _ConsoleCard({
    required this.controller,
    required this.scrollController,
  });

  final BuildController controller;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final progress = controller.progress.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return SectionCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.terminal,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text('Build output', style: theme.textTheme.titleSmall),
              const Spacer(),
              TextButton.icon(
                key: const ValueKey('saveLog'),
                onPressed: controller.log.isEmpty ? null : controller.saveLog,
                icon: const Icon(Icons.save_alt, size: 16),
                label: const Text('Save log'),
              ),
            ],
          ),
          if (progress.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final entry in progress)
              ByteProgress(
                label: entry.key,
                done: entry.value.done,
                total: entry.value.total,
              ),
          ],
          const SizedBox(height: 8),
          Container(
            key: const ValueKey('buildLog'),
            height: 340,
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF0B1017) : const Color(0xFF111827),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Scrollbar(
              controller: scrollController,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: scrollController,
                child: SelectableText(
                  controller.log.isEmpty
                      ? 'Waiting for a build. Configure your package above, '
                            'then select Build package.'
                      : controller.logText,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.45,
                    color: Color(0xFFD7E3F4),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.controller});

  final BuildController controller;

  @override
  Widget build(BuildContext context) {
    final summary = controller.summary;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const FieldLabel('YOUR PACKAGE'),
          const SizedBox(height: 8),
          Text(
            summary?['device'] as String? ?? 'No package yet',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (summary != null)
            Text(
              summary['kind'] as String? ?? '',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const Divider(height: 24),
          if (summary != null) ...[
            LabeledValue(label: 'System', value: '${summary['os']}'),
            LabeledValue(label: 'Region', value: '${summary['region']}'),
            LabeledValue(label: 'Output', value: '${summary['format']}'),
            LabeledValue(label: 'Version', value: '${summary['version']}'),
            LabeledValue(label: 'Engine', value: '${summary['engine']}'),
          ] else
            const HintText('Start a build to see its package details.'),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.controller});

  final BuildController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = controller.result!;
    final manifest = result['manifest'] is Map
        ? Map<String, Object?>.from(result['manifest']! as Map)
        : const <String, Object?>{};
    final arb = manifest['arb'] ?? result['arb'];
    final format = '${result['format'] ?? 'zip'}';
    final artifact = '${result['artifact'] ?? ''}';
    final job = '${result['job'] ?? ''}';
    final sha = result['sha256'];
    return SectionCard(
      key: const ValueKey('buildResult'),
      title: 'Result',
      trailing: Icon(
        Icons.check_circle,
        color: theme.colorScheme.primary,
        size: 20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabeledValue(label: 'Artifact', value: artifact),
          LabeledValue(label: 'Format', value: format),
          LabeledValue(label: 'Job', value: job),
          if (arb is Map)
            LabeledValue(
              label: 'ARB index',
              value:
                  '${arb['major'] ?? '?'}.${arb['minor'] ?? '?'}'
                  ' · ${arb['index'] ?? '?'}',
            )
          else if (arb != null)
            LabeledValue(label: 'ARB index', value: '$arb'),
          if (sha is String)
            LabeledValue(label: 'SHA-256', value: sha, monospace: true),
          const SizedBox(height: 10),
          if (format == 'zip')
            FilledButton.icon(
              key: const ValueKey('downloadZip'),
              onPressed: () => _download(context),
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Download ZIP'),
            )
          else
            HintText(
              'This build kept a flasher folder in the chosen output store. '
              'Folder builds are not a single download.',
            ),
          const SizedBox(height: 6),
          HintText(
            'The package and build.json are in $job in the selected store. '
            'Folder builds can be browsed from the folder you picked.',
          ),
        ],
      ),
    );
  }

  Future<void> _download(BuildContext context) async {
    final message = await controller.downloadArtifact();
    if (!context.mounted || message == null) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
