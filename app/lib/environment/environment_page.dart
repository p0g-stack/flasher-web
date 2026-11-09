import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

import '../format.dart';
import '../runtime.dart';
import '../setup/setup_state.dart';
import '../widgets/common.dart';

/// The facts, storage and browser support of this build environment.
class EnvironmentPage extends StatefulWidget {
  const EnvironmentPage({
    super.key,
    required this.runtime,
    required this.tables,
    required this.initial,
    required this.setup,
  });

  final AppRuntime runtime;
  final UpstreamTables tables;
  final EnvironmentInfo initial;

  /// Owns the budget reading and the cached OTA list of the bloat store.
  final SetupState setup;

  @override
  State<EnvironmentPage> createState() => _EnvironmentPageState();
}

class _EnvironmentPageState extends State<EnvironmentPage> {
  late EnvironmentInfo _environment = widget.initial;
  bool _loading = false;
  bool _requesting = false;
  String? _error;

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await widget.runtime.service.environment();
      if (!mounted) return;
      setState(() => _environment = EnvironmentInfo.fromJson(value));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _requestPersistent() async {
    setState(() => _requesting = true);
    try {
      final granted = await widget.runtime.bridge.requestPersistentStorage();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            granted
                ? 'Persistent storage granted for this origin.'
                : 'The browser did not grant persistent storage.',
          ),
        ),
      );
      await _refresh();
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final storage = _environment.storage;
    final picker = widget.runtime.bridge.canPickDirectory;
    final upstream = _environment.upstream.isNotEmpty
        ? _environment.upstream
        : widget.tables.commit;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionCard(
            title: 'Build environment',
            trailing: TextButton.icon(
              key: const ValueKey('refreshEnvironment'),
              onPressed: _loading ? null : _refresh,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Refresh'),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Check the local engine, storage and device support.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (_loading) ...[
                  const SizedBox(height: 10),
                  const LinearProgressIndicator(minHeight: 3),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  HintText(_error!, error: true),
                ],
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final two = constraints.maxWidth >= 720;
                    final values = <Widget>[
                      LabeledValue(
                        label: 'WASM',
                        value: _environment.native
                            ? 'Rust library available in the worker'
                            : 'Dart worker (Rust library unavailable)',
                      ),
                      LabeledValue(
                        label: 'Facts',
                        value: _environment.facts.isEmpty
                            ? 'Not reported'
                            : _environment.facts.join(', '),
                      ),
                      LabeledValue(
                        label: 'Upstream commit',
                        value: upstream.isEmpty ? 'Unknown' : upstream,
                        monospace: true,
                      ),
                      LabeledValue(
                        label: 'Workflow catalog',
                        value:
                            '${widget.tables.builders.length} supported device, '
                            'flasher and region combinations',
                      ),
                      LabeledValue(
                        label: 'Persistent storage',
                        value: storage.persisted ? 'Granted' : 'Not granted',
                      ),
                      LabeledValue(
                        label: 'Storage',
                        value: storage.quota > 0
                            ? '${formatBytes(storage.usage)} of '
                                  '${formatBytes(storage.quota)} used'
                            : 'Not reported',
                      ),
                    ];
                    if (!two) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: values,
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: values.sublist(0, 3),
                          ),
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: values.sublist(3),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                if (storage.quota > 0) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: storage.fraction,
                    minHeight: 6,
                  ),
                ],
                const SizedBox(height: 14),
                Row(
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('requestPersistentStorage'),
                      onPressed: storage.persisted || _requesting
                          ? null
                          : _requestPersistent,
                      icon: const Icon(Icons.shield_outlined, size: 18),
                      label: Text(
                        _requesting
                            ? 'Requesting…'
                            : storage.persisted
                            ? 'Storage is persistent'
                            : 'Request persistent storage',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const HintText(
                  'Persistent storage asks the browser not to evict cached '
                  'bloat and unfinished work. It is best effort and can be '
                  'revoked by the browser.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _StorageBudgetCard(setup: widget.setup),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Browser support',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SupportRow(
                  title: 'File System Access',
                  available: picker && storage.handle,
                  detail: picker && storage.handle
                      ? 'Available: choose a folder for the bloat cache and '
                            'OTAs.'
                      : 'Not available: bloat and OTAs use origin-private '
                            'storage.',
                ),
                const SizedBox(height: 10),
                _SupportRow(
                  title: 'Origin-private file system',
                  available: storage.opfs,
                  detail: storage.opfs
                      ? 'Available: bloat and package bytes stay in browser '
                            'storage until downloaded.'
                      : 'Not available: a folder must be chosen.',
                ),
                const SizedBox(height: 10),
                _SupportRow(
                  title: 'Streaming ZIP download',
                  available: true,
                  detail:
                      'Finished ZIPs download as a Blob from the selected '
                      'store; no upload is involved.',
                ),
                const SizedBox(height: 10),
                _SupportRow(
                  title: 'Screen wake lock',
                  available: true,
                  detail:
                      'Held while a flash, bloat download or ZIP export runs, '
                      'together with a leave guard.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Runtime facts',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_environment.facts.isEmpty)
                  const HintText('The service has not reported facts yet.')
                else
                  for (final fact in _environment.facts)
                    Chip(
                      label: Text(fact),
                      visualDensity: VisualDensity.compact,
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StorageBudgetCard extends StatelessWidget {
  const _StorageBudgetCard({required this.setup});

  final SetupState setup;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: setup,
      builder: (context, _) {
        final theme = Theme.of(context);
        final cap = setup.budgetCap;
        final usage = setup.budgetUsage;
        final fraction = cap > 0 ? (usage / cap).clamp(0.0, 1.0) : 0.0;
        final items = setup.cachedOtas;
        return SectionCard(
          title: 'Storage budget',
          trailing: TextButton.icon(
            key: const ValueKey('refreshBudget'),
            onPressed: setup.budgetLoading ? null : setup.refreshBudget,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(setup.budgetLoading ? 'Checking…' : 'Refresh'),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'This app keeps at most ${formatBytes(cap)} in browser '
                'storage. Bloat images and cached catalog OTAs share the '
                'budget; local OTA files are read in place and cost nothing.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(
                key: const ValueKey('storageBudgetBar'),
                value: fraction,
                minHeight: 8,
              ),
              const SizedBox(height: 8),
              LabeledValue(label: 'Used', value: formatBytes(usage)),
              LabeledValue(
                label: 'Free under the cap',
                value: formatBytes(setup.budgetAvailable),
              ),
              if (setup.budgetQuota > 0)
                LabeledValue(
                  label: 'Browser quota',
                  value:
                      '${formatBytes(usage)} of '
                      '${formatBytes(setup.budgetQuota)} used',
                ),
              if (setup.budgetError != null) ...[
                const SizedBox(height: 6),
                HintText(
                  setup.budgetError!,
                  key: const ValueKey('budgetError'),
                  error: true,
                ),
              ],
              const SizedBox(height: 14),
              const FieldLabel('CACHED OTAs'),
              const SizedBox(height: 4),
              if (items.isEmpty)
                const HintText(
                  'No catalog OTA is cached. Use Download OTA › App cache on '
                  'a catalog version to read the same release offline.',
                )
              else
                for (final item in items) _CachedOtaRow(setup: setup, item: item),
            ],
          ),
        );
      },
    );
  }
}

class _CachedOtaRow extends StatelessWidget {
  const _CachedOtaRow({required this.setup, required this.item});

  final SetupState setup;
  final Map<String, Object?> item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final key = item['key'];
    final keyText = key is String && key.isNotEmpty ? key : null;
    final bytes = item['bytes'];
    final complete = item['complete'] == true;
    final lastUsed = item['lastUsed'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            complete ? Icons.offline_pin : Icons.pending_outlined,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${item['label'] ?? key ?? 'OTA'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  [
                    if (bytes is num) formatBytes(bytes.toInt()),
                    complete ? 'complete' : 'partial',
                    if (lastUsed is String && lastUsed.isNotEmpty)
                      'last used ${formatCreated(lastUsed)}',
                  ].join(' · '),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          TextButton.icon(
            key: ValueKey('evict-$key'),
            onPressed: keyText == null
                ? null
                : () => setup.evictCachedOta(keyText),
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('Evict'),
          ),
        ],
      ),
    );
  }
}

class _SupportRow extends StatelessWidget {
  const _SupportRow({
    required this.title,
    required this.available,
    required this.detail,
  });

  final String title;
  final bool available;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          available ? Icons.check_circle : Icons.info_outline,
          size: 18,
          color: available
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.bodyMedium),
              Text(
                detail,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
