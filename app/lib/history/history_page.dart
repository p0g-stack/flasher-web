import 'dart:async';

import 'package:flutter/material.dart';

import '../flash/flash_target.dart';
import '../format.dart';
import '../runtime.dart';
import '../setup/setup_state.dart';
import '../widgets/common.dart';

/// Build history from `build.json` files in the current output store.
class HistoryPage extends StatefulWidget {
  const HistoryPage({
    super.key,
    required this.runtime,
    required this.setup,
    required this.onFlash,
  });

  final AppRuntime runtime;
  final SetupState setup;
  final void Function(FlashTarget target) onFlash;

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

  FlashTarget? _target(Map<String, Object?> item) {
    final job = item['job'];
    final device = item['device'];
    final kind = item['flasher_type'];
    final region = item['region'];
    if (job is! String || job.isEmpty) return null;
    if (device is! String || kind is! String || region is! String) return null;
    return FlashTarget(
      job: job,
      store: widget.setup.outputStore.toService(),
      selection: {'device': device, 'kind': kind, 'region': region},
      label: '$device / $kind',
    );
  }

  Future<void> _downloadReceipt(Map<String, Object?> item) async {
    final job = item['job'];
    final flash = item['flash'];
    if (job is! String || job.isEmpty || flash is! Map) return;
    final serial = '${flash['serial'] ?? 'device'}';
    final safe = serial.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    try {
      await widget.runtime.bridge.downloadStoreFile(
        '$job/flash-receipt.json',
        filename: 'flash-$job-$safe.json',
        handle: widget.setup.outputStore.directory?.handle,
      );
    } on Object catch (error) {
      if (mounted) _snack('Could not download the receipt: $error');
    }
  }

  void _showReceipt(Map<String, Object?> item) {
    final raw = item['flash'];
    if (raw is! Map) return;
    final receipt = Map<String, Object?>.from(raw);
    final steps = receipt['steps'] is List
        ? [
            for (final step in receipt['steps']! as List)
              if (step is Map) Map<String, Object?>.from(step),
          ]
        : const <Map<String, Object?>>[];
    final failure = receipt['failure'] is Map
        ? Map<String, Object?>.from(receipt['failure']! as Map)
        : null;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Flash receipt'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                LabeledValue(
                  label: 'Status',
                  value: '${receipt['status'] ?? ''}',
                ),
                LabeledValue(
                  label: 'Serial',
                  value: '${receipt['serial'] ?? ''}',
                  monospace: true,
                ),
                LabeledValue(
                  label: 'Product',
                  value: '${receipt['product'] ?? ''}',
                  monospace: true,
                ),
                LabeledValue(label: 'Job', value: '${receipt['job'] ?? ''}'),
                if (receipt['uncertain'] == true)
                  const HintText(
                    'Marked uncertain: a write may not have been confirmed.',
                    error: true,
                  ),
                if (failure != null)
                  HintText(
                    '${failure['name'] ?? ''}: ${failure['message'] ?? ''}',
                    error: true,
                  ),
                if (steps.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const FieldLabel('STEPS'),
                  for (final step in steps)
                    Text(
                      '${step['status'] ?? ''}  ${step['title'] ?? ''}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _downloadReceipt(item),
            child: const Text('Download'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
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
                    DataColumn(label: Text('FLASH')),
                    DataColumn(label: Text('')),
                  ],
                  rows: [for (final item in _items) _row(item)],
                ),
              ),
            const SizedBox(height: 10),
            const HintText(
              'Flash a finished package, download its ZIP or receipt, or '
              'delete the job folder. Folder builds are flashed through the '
              'same job path.',
            ),
          ],
        ),
      ),
    );
  }

  DataRow _row(Map<String, Object?> item) {
    final flash = item['flash'] is Map
        ? Map<String, Object?>.from(item['flash']! as Map)
        : null;
    final target = _target(item);
    return DataRow(
      cells: [
        DataCell(
          Text(
            _title(item),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        DataCell(Text('${item['region'] ?? ''}')),
        DataCell(Text('${item['version'] ?? ''}')),
        DataCell(Text(formatCreated(item['created']))),
        DataCell(
          flash == null
              ? const Text('Not flashed')
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${flash['status'] ?? 'unknown'}'),
                    IconButton(
                      tooltip: 'View flash receipt',
                      onPressed: () => _showReceipt(item),
                      icon: const Icon(Icons.receipt_long, size: 18),
                    ),
                    IconButton(
                      tooltip: 'Download flash receipt',
                      onPressed: () => _downloadReceipt(item),
                      icon: const Icon(Icons.download, size: 18),
                    ),
                  ],
                ),
        ),
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Flash this build',
                key: ValueKey('flash-${item['job']}'),
                onPressed: target == null ? null : () => widget.onFlash(target),
                icon: const Icon(Icons.flash_on, size: 18),
              ),
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
                icon: const Icon(Icons.delete_outline, size: 18),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _title(Map<String, Object?> item) {
    final test = item['test_fixture'] == true ? 'TEST · ' : '';
    final folder = item['output_format'] == 'folder' ? ' · Folder' : '';
    return '$test${item['device'] ?? 'Package'} / '
        '${item['flasher_type'] ?? ''}$folder';
  }
}
