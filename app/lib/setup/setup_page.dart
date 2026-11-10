import 'package:flutter/material.dart';

import '../format.dart';
import '../widgets/common.dart';
import 'ota_download_controller.dart';
import 'setup_state.dart';

/// The Flash or export page: steps 1–4 and the two actions.
class SetupPage extends StatelessWidget {
  const SetupPage({
    super.key,
    required this.setup,
    required this.onFlashDirect,
  });

  final SetupState setup;

  /// Opens the Flash page for the OTA-direct package.
  final VoidCallback? onFlashDirect;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: setup,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1180;
          final twoCards = constraints.maxWidth >= 900;
          final main = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (twoCards)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _ConfigureCard(setup: setup)),
                    const SizedBox(width: 16),
                    Expanded(child: _BloatCard(setup: setup)),
                  ],
                )
              else ...[
                _ConfigureCard(setup: setup),
                const SizedBox(height: 16),
                _BloatCard(setup: setup),
              ],
              const SizedBox(height: 16),
              _OtaCard(setup: setup),
              if (setup.isX9U) ...[
                const SizedBox(height: 16),
                _AblCard(setup: setup),
              ],
              const SizedBox(height: 16),
              _ActionsCard(setup: setup, onFlashDirect: onFlashDirect),
            ],
          );
          return SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 24),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: main),
                      const SizedBox(width: 20),
                      SizedBox(
                        width: 292,
                        child: _PackageSummary(setup: setup),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      main,
                      const SizedBox(height: 16),
                      _PackageSummary(setup: setup),
                    ],
                  ),
          );
        },
      ),
    );
  }
}

class _ConfigureCard extends StatelessWidget {
  const _ConfigureCard({required this.setup});

  final SetupState setup;

  @override
  Widget build(BuildContext context) {
    final regions = setup.regions;
    return SectionCard(
      number: '01',
      title: 'Package configuration',
      trailing: OsBadge(label: setup.osLabel),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _SelectionDropdown(
                  key: const ValueKey('deviceDropdown'),
                  label: 'DEVICE',
                  value: setup.device,
                  items: setup.tables.devices.keys.toList(),
                  display: (device) =>
                      device.replaceFirst('Oneplus', 'OnePlus'),
                  onChanged: setup.selectDevice,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _SelectionDropdown(
                  key: const ValueKey('kindDropdown'),
                  label: 'FLASHER TYPE',
                  value: setup.kind,
                  items: setup.kinds,
                  onChanged: setup.selectKind,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const FieldLabel('REGION'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 7,
            runSpacing: 6,
            children: [
              for (final region in regions)
                ChoiceChip(
                  key: ValueKey('region-$region'),
                  label: Text(region == 'GLO' ? 'Global' : region),
                  selected: setup.region == region,
                  onSelected: (_) => setup.selectRegion(region),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 12),
          HintText(setup.selectionInfo),
        ],
      ),
    );
  }
}

class _SelectionDropdown extends StatelessWidget {
  const _SelectionDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.display,
  });

  final String label;
  final String value;
  final List<String> items;
  final String Function(String value)? display;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldLabel(label),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(10),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              items: [
                for (final item in items)
                  DropdownMenuItem(
                    value: item,
                    child: Text(
                      display?.call(item) ?? item,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (next) {
                if (next != null) onChanged(next);
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _BloatCard extends StatelessWidget {
  const _BloatCard({required this.setup});

  final SetupState setup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = setup.bloatStore;
    final pending = setup.pendingBloatFolderName;
    final progress = setup.bloatProgress;
    return SectionCard(
      number: '02',
      title: 'Bloat files',
      trailing: IconButton(
        key: const ValueKey('recheckBloat'),
        tooltip: 'Recheck bloat files',
        onPressed: setup.bloatDownloading
            ? null
            : () => setup.refreshBloat(force: true),
        icon: const Icon(Icons.refresh, size: 20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  setup.bloatStatusText,
                  key: const ValueKey('bloatStatus'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: setup.bloatReady ? theme.colorScheme.primary : null,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  setup.bloatInfo,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Storage: ${store.name}',
            style: theme.textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (setup.pickerAvailable) ...[
                OutlinedButton.icon(
                  key: const ValueKey('chooseBloatFolder'),
                  onPressed: setup.canChangeStores
                      ? setup.chooseBloatFolder
                      : null,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: Text(
                    store.isFolder ? 'Change folder' : 'Choose folder',
                  ),
                ),
                if (pending != null && !store.isFolder)
                  TextButton(
                    key: const ValueKey('reconnectBloatFolder'),
                    onPressed: setup.reconnectBloatFolder,
                    child: Text('Reconnect $pending'),
                  ),
                if (store.isFolder)
                  TextButton(
                    key: const ValueKey('browseBloatBrowser'),
                    onPressed: setup.canChangeStores
                        ? setup.useBrowserStorage
                        : null,
                    child: const Text('Use browser storage'),
                  ),
              ] else
                HintText(
                  setup.opfsAvailable
                      ? 'File System Access is not available here; bloat files '
                            'stay in browser storage.'
                      : 'No writable storage is available in this browser.',
                ),
            ],
          ),
          if (setup.bloatDownloading) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(minHeight: 5),
            if (progress.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ByteProgress(
                  label: progress.keys.last,
                  done: progress.values.last.done,
                  total: progress.values.last.total,
                ),
              ),
            if (setup.bloatLog.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  setup.bloatLog.last,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
          if (setup.bloatError != null) ...[
            const SizedBox(height: 8),
            HintText(setup.bloatError!, error: true),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton.tonalIcon(
                key: const ValueKey('downloadBloat'),
                onPressed: setup.canDownloadBloat ? setup.downloadBloat : null,
                icon: Icon(
                  setup.bloatReady ? Icons.check : Icons.download,
                  size: 18,
                ),
                label: Text(setup.bloatButtonLabel),
              ),
              if (setup.bloatDownloading) ...[
                const SizedBox(width: 8),
                TextButton(
                  key: const ValueKey('cancelBloat'),
                  onPressed: setup.cancelBloat,
                  child: const Text('Cancel download'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _OtaCard extends StatelessWidget {
  const _OtaCard({required this.setup});

  final SetupState setup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      number: '03',
      title: 'OTA source',
      trailing: SegmentedButton<OtaMode>(
        key: const ValueKey('otaMode'),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: OtaMode.localFile,
            label: Text('Local file'),
            icon: Icon(Icons.insert_drive_file_outlined, size: 16),
          ),
          ButtonSegment(
            value: OtaMode.catalog,
            label: Text('Version catalog'),
            icon: Icon(Icons.download_outlined, size: 16),
          ),
        ],
        selected: {setup.otaMode},
        onSelectionChanged: (selection) => setup.setOtaMode(selection.single),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (setup.otaMode == OtaMode.localFile)
            _LocalOtaPanel(setup: setup)
          else
            _CatalogOtaPanel(setup: setup),
          const SizedBox(height: 10),
          HintText(setup.sourceHint),
          const SizedBox(height: 8),
          Text(
            'Full OTA packages only. Incremental updates are rejected.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _LocalOtaPanel extends StatelessWidget {
  const _LocalOtaPanel({required this.setup});

  final SetupState setup;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _LocalOtaRole(
          setup: setup,
          role: 'ota',
          title: 'FULL OTA PACKAGE',
          buttonKey: 'chooseOtaFile',
        ),
        if (setup.needsBase) ...[
          const SizedBox(height: 14),
          _LocalOtaRole(
            setup: setup,
            role: 'base',
            title: 'ACE 6 COLOROS BASE OTA',
            buttonKey: 'chooseBaseFile',
          ),
        ],
      ],
    );
  }
}

class _LocalOtaRole extends StatelessWidget {
  const _LocalOtaRole({
    required this.setup,
    required this.role,
    required this.title,
    required this.buttonKey,
  });

  final SetupState setup;
  final String role;
  final String title;
  final String buttonKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = setup.localFile(role);
    final inspection = setup.inspection(role);
    final error = setup.inspectionError(role);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldLabel(title),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
            color: theme.colorScheme.surfaceContainerLowest,
          ),
          child: Row(
            children: [
              Icon(
                file == null
                    ? Icons.upload_file_outlined
                    : Icons.check_circle_outline,
                color: file == null
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file?.name ?? 'Drop a full OTA .zip here or choose one',
                      style: theme.textTheme.bodyMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      file == null
                          ? 'The file is read in place; it is never uploaded.'
                          : '${formatBytes(file.size)} · read in place',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (file != null)
                IconButton(
                  tooltip: 'Remove file',
                  onPressed: () => setup.clearLocalFile(role),
                  icon: const Icon(Icons.close, size: 18),
                ),
              const SizedBox(width: 6),
              FilledButton.tonal(
                key: ValueKey(buttonKey),
                onPressed: () => setup.pickLocalFile(role),
                child: const Text('Choose ZIP'),
              ),
            ],
          ),
        ),
        if (setup.pendingOtaName != null && file == null && role == 'ota')
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('reconnectOtaFile'),
                onPressed: setup.reconnectOtaFile,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text('Reconnect ${setup.pendingOtaName}'),
              ),
            ),
          ),
        if (setup.inspecting(role))
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(minHeight: 3),
          ),
        if (inspection != null) ...[
          const SizedBox(height: 8),
          _InspectionCard(result: inspection),
        ],
        if (error != null) ...[
          const SizedBox(height: 8),
          HintText('Could not inspect this OTA: $error', error: true),
        ],
      ],
    );
  }
}

class _InspectionCard extends StatelessWidget {
  const _InspectionCard({required this.result});

  final Map<String, Object?> result;

  @override
  Widget build(BuildContext context) {
    final fields = result['fields'] is Map
        ? Map<String, Object?>.from(result['fields']! as Map)
        : const <String, Object?>{};
    final partitions = result['partitions'];
    final arb = result['arb'];
    final model = result['device'] ?? fields['pre-device'];
    final patch =
        result['securityPatch'] ?? fields['post-security-patch-level'];
    final length = result['length'];
    final values = <(String, String)>[
      ('Version', '${result['version'] ?? 'Unknown'}'),
      if (model != null) ('Model', '$model'),
      if (patch != null) ('Security patch', '$patch'),
      if (arb is Map)
        (
          'ARB index',
          '${arb['major'] ?? '?'}.${arb['minor'] ?? '?'}'
              ' · index ${arb['index'] ?? '?'}',
        ),
      if (partitions is Map) ('Partitions', '${partitions.length}'),
      if (length is num) ('Size', formatBytes(length.toInt())),
      if (fields['post-build'] != null) ('Build', '${fields['post-build']}'),
    ];
    return Container(
      key: const ValueKey('otaInspection'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer
            .withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, value) in values)
            LabeledValue(label: label, value: value),
        ],
      ),
    );
  }
}

class _CatalogOtaPanel extends StatelessWidget {
  const _CatalogOtaPanel({required this.setup});

  final SetupState setup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                setup.catalogStatusText,
                key: const ValueKey('catalogStatus'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: setup.catalogError != null
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.tonalIcon(
              key: const ValueKey('fetchVersions'),
              onPressed: setup.catalogLoading || !setup.selectionValid
                  ? null
                  : () => setup.fetchCatalog(force: true),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: Text(
                setup.catalogLoading ? 'Fetching…' : 'Fetch versions',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final role in const ['ota', 'base'])
          if (setup.selectedRelease(role) != null ||
              role == 'ota' ||
              setup.needsBase) ...[
            _CatalogRole(setup: setup, role: role),
            const SizedBox(height: 12),
          ],
        if (setup.needsMatchedOdm)
          Container(
            key: const ValueKey('odmStatus'),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: setup.odmError != null
                  ? theme.colorScheme.errorContainer.withValues(alpha: 0.4)
                  : theme.colorScheme.secondaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              setup.odmError != null
                  ? setup.odmError!
                  : setup.odmDonor != null
                  ? 'Matched ODM donor: Ace 6T CN ${setup.odmDonor}'
                  : 'Select a target version to find the matching Ace 6T CN '
                        'ODM donor.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _CatalogRole extends StatelessWidget {
  const _CatalogRole({required this.setup, required this.role});

  final SetupState setup;
  final String role;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final releases = setup.releasesForRole(role);
    final selected = setup.selectedRelease(role);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldLabel(role == 'ota' ? 'TARGET OTA' : 'ACE 6 COLOROS BASE OTA'),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(10),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              key: ValueKey('catalog-$role'),
              value: selected?['id'] as String?,
              isExpanded: true,
              hint: const Text('Fetch versions to choose a release'),
              items: [
                for (final entry in releases)
                  DropdownMenuItem(
                    value: entry['id'] as String,
                    child: Text(
                      '${entry['version']}'
                      '${entry['is_latest'] == true ? ' · Latest' : ''}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (id) {
                if (id != null) setup.selectCatalogRelease(role, id);
              },
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          setup.catalogDetail(role),
          key: ValueKey('catalogDetail-$role'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (selected != null) ...[
          const SizedBox(height: 6),
          _OtaDownload(setup: setup, role: role, entry: selected),
        ],
      ],
    );
  }
}

/// The catalog OTA's download button, its progress and its outcome.
class _OtaDownload extends StatelessWidget {
  const _OtaDownload({
    required this.setup,
    required this.role,
    required this.entry,
  });

  final SetupState setup;
  final String role;
  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final downloads = setup.otaDownloads;
    final mine = downloads.role == role;
    final size = entry['size'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (setup.isOtaCached(entry))
          HintText(
            'A complete offline copy is cached in the app storage.',
            key: ValueKey('catalogCached-$role'),
          ),
        if (downloads.running && mine) ...[
          Text(
            downloads.target == OtaDownloadTarget.cache
                ? 'Downloading into the app cache…'
                : 'Saving to this computer…',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          for (final item in downloads.progress.entries)
            ByteProgress(
              label: item.key,
              done: item.value.done,
              total: item.value.total,
              detail: _transferDetail(downloads, item.key, item.value),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: ValueKey('cancelOtaDownload-$role'),
              onPressed: downloads.cancel,
              icon: const Icon(Icons.stop, size: 16),
              label: const Text('Cancel download'),
            ),
          ),
        ] else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: ValueKey('downloadOta-$role'),
              onPressed: setup.canDownloadOta(role)
                  ? () => _choose(context)
                  : null,
              icon: const Icon(Icons.download_outlined, size: 18),
              label: Text(
                size is num && size > 0
                    ? 'Download OTA · ${formatBytes(size.toInt())}'
                    : 'Download OTA',
              ),
            ),
          ),
        if (!downloads.running && downloads.pendingSave?.role == role) ...[
          HintText(
            '${downloads.pendingSave!.name} was not finished. Resume writes '
            'only the missing parts into the same file.',
            key: ValueKey('pendingOtaSave-$role'),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                key: ValueKey('resumeOtaSave-$role'),
                onPressed: setup.resumeOtaSave,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Resume save'),
              ),
              TextButton(
                key: ValueKey('discardOtaSave-$role'),
                onPressed: downloads.discardSave,
                child: const Text('Discard'),
              ),
            ],
          ),
        ],
        if (mine && downloads.notice != null)
          HintText(downloads.notice!, key: ValueKey('otaDownloadNotice-$role')),
        if (mine && downloads.error != null)
          HintText(
            downloads.error!,
            key: ValueKey('otaDownloadError-$role'),
            error: true,
          ),
      ],
    );
  }

  static String _transferDetail(
    OtaDownloadController downloads,
    String label,
    ({int done, int total}) progress,
  ) {
    final parts = [
      '${formatBytes(progress.done)} of ${formatBytes(progress.total)}',
    ];
    final rate = downloads.rate(label);
    if (rate != null) parts.add('${formatBytes(rate.round())}/s');
    final resumed = downloads.resumedFrom(label);
    if (resumed > 0) {
      parts.add('resumed with ${formatBytes(resumed)} already saved');
    }
    return parts.join(' · ');
  }

  Future<void> _choose(BuildContext context) async {
    final target = await showDialog<OtaDownloadTarget>(
      context: context,
      builder: (context) => _OtaDownloadDialog(setup: setup, entry: entry),
    );
    switch (target) {
      case OtaDownloadTarget.computer:
        // The dialog's tap is the gesture the save picker needs.
        await setup.downloadOtaToComputer(role);
      case OtaDownloadTarget.cache:
        await setup.downloadOtaToCache(role);
      case null:
        break;
    }
  }
}

/// Asks where a catalog OTA goes: onto this computer or into the app cache.
class _OtaDownloadDialog extends StatelessWidget {
  const _OtaDownloadDialog({required this.setup, required this.entry});

  final SetupState setup;
  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final downloads = setup.otaDownloads;
    final cached = setup.isOtaCached(entry);
    final fits = setup.otaFitsCache(entry);
    final String cacheText;
    if (cached) {
      cacheText = 'Already cached; a flash of this version reads it.';
    } else if (fits) {
      cacheText =
          'Keep it in browser storage, under the app storage cap '
          '(${formatBytes(setup.budgetAvailable)} free). A flash of this '
          'version then reads it instead of the network; an interrupted '
          'download resumes.';
    } else if (setup.budget == null) {
      cacheText = 'The app storage budget is unknown, so nothing is cached.';
    } else {
      cacheText =
          'Does not fit the remaining ${formatBytes(setup.budgetAvailable)} '
          'under the app storage cap. Evict a cached OTA from Environment '
          'first.';
    }
    final computerText = !downloads.canSaveToComputer
        ? 'This browser cannot save files.'
        : downloads.savesIntoPickedFile
        ? 'Save the ZIP where you choose, outside the app storage cap. The '
              'app then reads it as the local OTA.'
        : 'Download the ZIP to the browser downloads, outside the app '
              'storage cap. Choose it under Local file afterwards.';
    return AlertDialog(
      title: const Text('Download OTA'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('downloadOtaComputer'),
              enabled: downloads.canSaveToComputer,
              leading: const Icon(Icons.computer_outlined),
              title: const Text('This computer'),
              subtitle: Text(computerText),
              onTap: () =>
                  Navigator.of(context).pop(OtaDownloadTarget.computer),
            ),
            ListTile(
              key: const ValueKey('downloadOtaCache'),
              enabled: fits && !cached,
              leading: const Icon(Icons.download_for_offline_outlined),
              title: const Text('App cache'),
              subtitle: Text(cacheText),
              onTap: () => Navigator.of(context).pop(OtaDownloadTarget.cache),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _AblCard extends StatelessWidget {
  const _AblCard({required this.setup});

  final SetupState setup;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      number: '04',
      title: 'Vulnerable ABL',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const FieldLabel('Pack ABL 16.0.6?'),
          const SizedBox(width: 10),
          ChoiceChip(
            key: const ValueKey('ablYes'),
            label: const Text('Yes'),
            selected: setup.vulnerableAbl == true,
            onSelected: (_) => setup.setVulnerableAbl(true),
          ),
          const SizedBox(width: 6),
          ChoiceChip(
            key: const ValueKey('ablNo'),
            label: const Text('No'),
            selected: setup.vulnerableAbl == false,
            onSelected: (_) => setup.setVulnerableAbl(false),
          ),
        ],
      ),
      child: HintText(
        setup.vulnerableAbl == null
            ? 'Choose Yes or No to continue.'
            : setup.vulnerableAbl!
            ? 'ABL 16.0.6 will be packed.'
            : 'The OTA’s ABL will be kept.',
      ),
    );
  }
}

class _ActionsCard extends StatelessWidget {
  const _ActionsCard({required this.setup, this.onFlashDirect});

  final SetupState setup;
  final VoidCallback? onFlashDirect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final exports = setup.exports;
    final directError = setup.directFlashRequirementsError;
    final exportError = setup.exportRequirementsError;
    final result = exports.result;
    return AnimatedBuilder(
      animation: exports,
      builder: (context, _) {
        final actions = Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Tooltip(
              key: const ValueKey('directFlashHint'),
              message: directError.isEmpty
                  ? setup.directFlashHint
                  : directError,
              child: FilledButton.icon(
                key: const ValueKey('flashDirectButton'),
                onPressed: setup.canFlashDirect && onFlashDirect != null
                    ? onFlashDirect
                    : null,
                icon: const Icon(Icons.flash_on, size: 18),
                label: const Text('Flash directly'),
              ),
            ),
            Tooltip(
              key: const ValueKey('exportZipHint'),
              message: exportError.isEmpty
                  ? 'Save or download the same package as a ZIP file.'
                  : exportError,
              child: FilledButton.tonalIcon(
                key: const ValueKey('exportZipButton'),
                onPressed: setup.canExportZip && !exports.exporting
                    ? () => _export(context)
                    : null,
                icon: const Icon(Icons.save_alt, size: 18),
                label: Text(exports.exporting ? 'Exporting…' : 'Export ZIP'),
              ),
            ),
          ],
        );
        return SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, constraints) => constraints.maxWidth < 760
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'The OTA and the verified bloat images are read in '
                            'place. Flash the phone over fastboot or save the '
                            'same package as a ZIP.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerRight,
                            child: actions,
                          ),
                        ],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Text(
                              'The OTA and the verified bloat images are read '
                              'in place. Flash the phone over fastboot or save '
                              'the same package as a ZIP.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          actions,
                        ],
                      ),
              ),
              if (!setup.canSaveZip) ...[
                const SizedBox(height: 8),
                HintText(
                  exportError,
                  key: const ValueKey('exportUnavailable'),
                  error: true,
                ),
              ],
              if (setup.directFlashSupported && directError.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  directError,
                  key: const ValueKey('directFlashError'),
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              if (setup.storeError != null) ...[
                const SizedBox(height: 6),
                Text(
                  setup.storeError!,
                  key: const ValueKey('storeError'),
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              if (exports.exporting) ...[
                const SizedBox(height: 10),
                const LinearProgressIndicator(minHeight: 5),
                for (final entry in exports.progress.entries)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: ByteProgress(
                      label: entry.key,
                      done: entry.value.done,
                      total: entry.value.total,
                    ),
                  ),
                if (exports.log.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      exports.log.last,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
              if (result != null) ...[
                const SizedBox(height: 10),
                Container(
                  key: const ValueKey('exportResult'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withValues(
                      alpha: 0.25,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LabeledValue(
                        label: 'Job',
                        value: '${result['job'] ?? ''}',
                        monospace: true,
                      ),
                      LabeledValue(
                        label: 'SHA-256',
                        value: '${result['sha256'] ?? ''}',
                        monospace: true,
                      ),
                      LabeledValue(
                        label: 'Bytes',
                        value: '${result['bytes'] ?? ''}',
                      ),
                      LabeledValue(
                        label: 'Entries',
                        value: '${result['entries'] ?? ''}',
                      ),
                    ],
                  ),
                ),
              ],
              if (exports.error != null) ...[
                const SizedBox(height: 6),
                HintText(
                  exports.error!,
                  key: const ValueKey('exportError'),
                  error: true,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _export(BuildContext context) async {
    final message = await setup.exportZip();
    if (!context.mounted || message == null) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _PackageSummary extends StatelessWidget {
  const _PackageSummary({required this.setup});

  final SetupState setup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final storage = setup.environment.storage;
    final free = storage.quota - storage.usage;
    final summary = setup.packageSummary;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FieldLabel('YOUR PACKAGE'),
          const SizedBox(height: 8),
          Text(summary['device']! as String, style: theme.textTheme.titleLarge),
          Text(
            summary['kind']! as String,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Divider(height: 24),
          LabeledValue(label: 'System', value: summary['os']! as String),
          LabeledValue(label: 'Region', value: summary['region']! as String),
          LabeledValue(label: 'Output', value: summary['format']! as String),
          LabeledValue(label: 'Engine', value: summary['engine']! as String),
          LabeledValue(label: 'Version', value: summary['version']! as String),
          const Divider(height: 24),
          HintText(
            storage.quota > 0
                ? '${formatBytes(free)} available in browser storage\n'
                      '${free < 40 * 1024 * 1024 * 1024 ? 'Choose a bloat folder for large downloads.' : 'Browser quota is not physical disk free space.'}'
                : 'Browser storage quota is not reported.',
          ),
          if (!setup.bloatStore.isFolder) ...[
            const SizedBox(height: 6),
            HintText(
              storage.quota > 0
                  ? 'Bloat cache and OTAs use browser storage: '
                        '${formatBytes(free)} available.'
                  : 'Bloat cache and OTAs use browser storage.',
            ),
          ],
          if (!storage.persisted) ...[
            const SizedBox(height: 6),
            HintText(
              'Storage is not persistent yet; request it from Environment.',
            ),
          ],
        ],
      ),
    );
  }
}
