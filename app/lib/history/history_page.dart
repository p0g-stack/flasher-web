import 'dart:async';

import 'package:flutter/material.dart';

import '../format.dart';
import '../runtime.dart';
import '../setup/setup_state.dart';
import '../widgets/common.dart';

/// Build history from `build.json` files in the current output store.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.runtime, required this.setup});

  final AppRuntime runtime;
  final SetupState setup;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<Map<String, Object?>> _items = const [];
  bool _loading = true;
  String? _error;
  String _storeKey = '';

  @override
  void initState() {
    super.initState();
    widget.setup.addListener(_storeChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.setup.removeListener(_storeChanged);
    super.dispose();
  }

  void _storeChanged() {
    final key = widget.setup.outputStore.name;
    if (key == _storeKey) return;
    _storeKey = key;
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.runtime.service.history({
        'output': widget.setup.outputStore.toService(),
      });
      if (!mounted) return;
      setState(() => _items = items);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _download(Map<String, Object?> item) async {
    final format = item['output_format'] ?? item['format'];
    final artifact = item['artifact'];
    final job = item['job'];
    if (format != 'zip' || artifact is! String || job is! String) {
      _snack(
        'This is a folder build. Open it from the output folder you picked.',
      );
      return;
    }
    try {
      await widget.runtime.bridge.downloadStoreFile(
        '$job/$artifact',
        filename: artifact,
        handle: widget.setup.outputStore.directory?.handle,
      );
    } on Object catch (error) {
      if (mounted) _snack('Could not download $artifact: $error');
    }
  }

  Future<void> _delete(Map<String, Object?> item) async {
    final job = item['job'];
    if (job is! String) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this build?'),
        content: Text(
          'The job folder $job, including its package, build.json and '
          'build.log, will be removed from the selected output store.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.runtime.bridge.deleteStorePath(
        job,
        handle: widget.setup.outputStore.directory?.handle,
      );
      await _load();
    } on Object catch (error) {
      if (mounted) _snack('Could not delete $job: $error');
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: SectionCard(
        title: 'Recent packages',
        trailing: TextButton.icon(
          key: const ValueKey('refreshHistory'),
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Refresh'),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Packages in ${widget.setup.outputStore.name}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const LinearProgressIndicator(minHeight: 3)
            else if (_error != null)
              HintText(_error!, error: true)
            else if (_items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 36),
                child: HintText(
                  'No packages yet. Finished builds appear here with their '
                  'region, version and creation time.',
                ),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('PACKAGE')),
                    DataColumn(label: Text('REGION')),
                    DataColumn(label: Text('VERSION')),
                    DataColumn(label: Text('CREATED')),
                    DataColumn(label: Text('')),
                  ],
                  rows: [
                    for (final item in _items)
                      DataRow(
                        cells: [
                          DataCell(
                            Text(
                              _title(item),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          DataCell(Text('${item['region'] ?? ''}')),
                          DataCell(Text('${item['version'] ?? ''}')),
                          DataCell(Text(formatCreated(item['created']))),
                          DataCell(
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Download ZIP',
                                  onPressed: item['output_format'] == 'folder'
                                      ? null
                                      : () => _download(item),
                                  icon: const Icon(Icons.download, size: 18),
                                ),
                                IconButton(
                                  tooltip: 'Delete build',
                                  onPressed: () => _delete(item),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            const HintText(
              'Download a ZIP or delete a job folder. Folder builds can be '
              'browsed from the output folder you picked.',
            ),
          ],
        ),
      ),
    );
  }

  String _title(Map<String, Object?> item) {
    final test = item['test_fixture'] == true ? 'TEST · ' : '';
    final folder = item['output_format'] == 'folder' ? ' · Folder' : '';
    return '$test${item['device'] ?? 'Package'} / '
        '${item['flasher_type'] ?? ''}$folder';
  }
}
