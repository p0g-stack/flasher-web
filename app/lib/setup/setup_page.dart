import 'package:flutter/material.dart';

import '../format.dart';
import '../widgets/common.dart';
import 'setup_state.dart';

/// The New package page: steps 1–4, output choice and Build.
class SetupPage extends StatelessWidget {
  const SetupPage({super.key, required this.setup, required this.onBuild});

  final SetupState setup;
  final VoidCallback onBuild;

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
              _OutputBar(setup: setup, onBuild: onBuild),
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
    final pending = setup.pendingFolderName(StoreTarget.bloat);
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
          if (setup.hostedBuild) ...[
            const SizedBox(height: 6),
            HintText(
              'The hosted builder uses its own verified bloat cache. This '
              'local copy is only needed for local builds.',
            ),
          ],
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
                      ? () => setup.chooseFolder(StoreTarget.bloat)
                      : null,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: Text(
                    store.isFolder ? 'Change folder' : 'Choose folder',
                  ),
                ),
                if (pending != null && !store.isFolder)
                  TextButton(
                    key: const ValueKey('reconnectBloatFolder'),
                    onPressed: () => setup.reconnectFolder(StoreTarget.bloat),
                    child: Text('Reconnect $pending'),
                  ),
                if (store.isFolder)
                  TextButton(
                    key: const ValueKey('browseBloatBrowser'),
                    onPressed: setup.canChangeStores
                        ? () => setup.useBrowserStorage(StoreTarget.bloat)
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
          Container(
            key: const ValueKey('hostedBuildPanel'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
              color: setup.hostedBuild
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                  : null,
            ),
            child: Row(
              children: [
                Icon(
                  setup.hostedBuild
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_outlined,
                  size: 18,
                  color: setup.hostedAvailable
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Build on the hosted server',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        setup.hostedAvailable
                            ? 'Catalog OTA only · the server uses the release '
                                  'ID, never a local file or custom URL.'
                            : 'Switch to Version catalog to use a hosted build.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  key: const ValueKey('hostedBuildSwitch'),
                  value: setup.hostedBuild,
                  onChanged: setup.hostedAvailable
                      ? setup.setHostedBuild
                      : null,
                ),
              ],
            ),
          ),
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

class _OutputBar extends StatelessWidget {
  const _OutputBar({required this.setup, required this.onBuild});

  final SetupState setup;
  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = setup.outputStore;
    final pending = setup.pendingFolderName(StoreTarget.output);
    final error = setup.buildRequirementsError;
    return SectionCard(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 760;
          final storage = setup.hostedBuild
              ? _HostedOutputInfo(setup: setup)
              : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              FieldLabel('SAVE PACKAGE TO'),
              const SizedBox(height: 5),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    store.isFolder ? Icons.folder : Icons.cloud_outlined,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      store.name,
                      key: const ValueKey('outputStore'),
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  if (setup.pickerAvailable)
                    TextButton(
                      key: const ValueKey('chooseOutputFolder'),
                      onPressed: () => setup.chooseFolder(StoreTarget.output),
                      child: Text(
                        store.isFolder ? 'Change folder' : 'Choose folder',
                      ),
                    ),
                  if (pending != null && !store.isFolder)
                    TextButton(
                      key: const ValueKey('reconnectOutputFolder'),
                      onPressed: () =>
                          setup.reconnectFolder(StoreTarget.output),
                      child: Text('Reconnect $pending'),
                    ),
                  if (store.isFolder)
                    TextButton(
                      key: const ValueKey('outputBrowser'),
                      onPressed: () =>
                          setup.useBrowserStorage(StoreTarget.output),
                      child: const Text('Use browser storage'),
                    ),
                ],
              ),
              if (!store.isFolder)
                Text(
                  'The ZIP downloads from browser storage when the build '
                  'finishes.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          );
          final actions = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!setup.hostedBuild)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      key: const ValueKey('zipBuild'),
                      value: setup.zipOutput,
                      onChanged: (value) => setup.setZipOutput(value ?? true),
                    ),
                    const Text('ZIP build'),
                  ],
                ),
              const SizedBox(width: 10),
              Tooltip(
                message: error.isEmpty ? 'Build the package' : error,
                child: FilledButton.icon(
                  key: const ValueKey('buildButton'),
                  onPressed: setup.canBuild ? onBuild : null,
                  icon: const Icon(Icons.arrow_forward, size: 18),
                  label: Text(
                    setup.hostedBuild ? 'Build on server' : 'Build package',
                  ),
                ),
              ),
            ],
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (compact) ...[
                storage,
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerRight, child: actions),
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: storage),
                    const SizedBox(width: 16),
                    actions,
                  ],
                ),
              if (error.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  error,
                  key: const ValueKey('gatingError'),
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
            ],
          );
        },
      ),
    );
  }
}

class _HostedOutputInfo extends StatelessWidget {
  const _HostedOutputInfo({required this.setup});

  final SetupState setup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final version = setup.selectedVersion;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const FieldLabel('BUILD LOCATION'),
        const SizedBox(height: 5),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Hosted server',
                key: const ValueKey('hostedOutput'),
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          version == null
              ? 'Catalog release · ZIP only · no local output store is used.'
              : '$version · ZIP only · the finished artifact stays on the '
                    'server.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'The ZIP can be downloaded or range-flashed from the same origin.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Identical requests may reuse a cached build. The operator retains '
          'catalog OTAs and ZIPs for its configured period (default 150 days '
          'since last use).',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
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
    final outputIsFolder = setup.outputStore.isFolder;
    final usesBrowserStorage = !outputIsFolder || !setup.bloatStore.isFolder;
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
            outputIsFolder
                ? 'Output uses the selected folder. The browser cannot report '
                      'its free disk space.'
                : storage.quota > 0
                ? '${formatBytes(free)} available in browser storage\n'
                      '${free < 40 * 1024 * 1024 * 1024 ? 'Choose a folder for large full builds.' : 'Browser quota is not physical disk free space.'}'
                : 'Browser storage quota is not reported.',
          ),
          if (outputIsFolder && !setup.bloatStore.isFolder) ...[
            const SizedBox(height: 6),
            HintText(
              storage.quota > 0
                  ? 'Bloat cache still uses browser storage: '
                        '${formatBytes(free)} available.'
                  : 'Bloat cache still uses browser storage.',
            ),
          ],
          if (usesBrowserStorage && !storage.persisted) ...[
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
