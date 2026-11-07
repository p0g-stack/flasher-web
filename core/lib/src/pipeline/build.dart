/// The flasher build: OTA preparation, staging, partition extraction,
/// conversion, packaging and the job manifest.
///
/// Port of `backend.build`, `native_pipeline.stage` and
/// `native_pipeline.build_images`. I/O goes through a [Workspace]; OTA
/// metadata, manifests and image operations go through [OtaArchive] and
/// [extractPartitions].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../bloat/bloat_store.dart';
import '../bloat/manifest.dart';
import '../catalog/catalog_client.dart';
import '../catalog/http_transport.dart';
import '../catalog/ota_catalog.dart';
import '../facts/facts.dart';
import '../native/native.dart' show loadNative;
import '../rust/api/avb.dart';
import '../rust/api/payload.dart';
import '../service/storage_stats.dart';
import '../storage/paths.dart' show baseWorkspacePath;
import '../storage/storage.dart';
import '../upstream/bloat_selection.dart';
import '../upstream/tables.dart';
import 'assets.dart';
import 'errors.dart';
import 'extract.dart';
import 'local_source.dart';
import 'ota.dart';
import 'ota_headers.dart';
import 'package.dart';

/// Builds one flasher package.
///
/// [req] is the service contract's build request: `selection`, `ota`,
/// optional `base`, optional `vulnerableAbl`, `zip`, `bloat`, `output`,
/// `apiBase` and `upstreamBase`. Events are `step`, `log`, `progress` and a
/// final `result`, as `docs/service.md` describes.
///
/// Cancelling the subscription cancels the job and removes its folder.
Stream<Map<String, Object?>> buildFlasher(Map<String, Object?> req) {
  final controller = StreamController<Map<String, Object?>>();
  final run = _BuildRun(req, controller);
  controller.onListen = () {
    unawaited(run._start());
  };
  controller.onCancel = run._cancel;
  return controller.stream;
}

const int _gib = 1024 * 1024 * 1024;
const int _chunk = 4 * 1024 * 1024;
const String _x9uAblSha256 =
    '4ad7f1db0c92f0a358e28bf18170a20533011299827d8d9a25cffd2218f1415d';
const Set<String> _scrapFiles = {
  'dtbo.img',
  'dtbo_patched.img',
  'dtbo_patcher.sh',
  'dtbo_patcher.py',
  'dtbo_patcher',
};

final class _BuildRun {
  _BuildRun(this._req, this._controller);

  final Map<String, Object?> _req;
  final StreamController<Map<String, Object?>> _controller;
  Completer<void>? _done;
  bool _cancelled = false;
  String? _job;
  _BuildLog? _log;
  HttpCatalogTransport? _transport;
  CatalogClient? _client;
  Map<String, dynamic>? _catalogData;
  bool _proxyOta = false;

  void _check() {
    if (_cancelled) throw const CancelledException();
  }

  void _emit(Map<String, Object?> event) {
    _check();
    if (_controller.isClosed) return;
    _controller.add(event);
  }

  Future<void> _logLine(String text) async {
    final log = _log;
    if (log != null) await log.write(text);
    _emit({'type': 'log', 'text': text});
  }

  Future<void> _step(int index, String title) async {
    final log = _log;
    if (log != null) await log.write('STEP $index/5 • $title');
    _emit({'type': 'step', 'index': index, 'total': 5, 'title': title});
  }

  Future<void> _start() async {
    final done = _done = Completer<void>();
    try {
      await _execute();
    } catch (error, stack) {
      if (error is CancelledException || _cancelled) {
        _cancelled = true;
      } else {
        await _writeError(error);
        if (!_controller.isClosed) _controller.addError(error, stack);
      }
    } finally {
      final log = _log;
      if (log != null) await log.close();
      if (_cancelled) await _deleteJob();
      try {
        _transport?.close();
      } on Object {
        // The HTTP catalog transport is already unusable at this point.
      }
      if (!done.isCompleted) done.complete();
      if (!_controller.isClosed) {
        try {
          await _controller.close();
        } on Object {
          // A cancelled subscription does not need a close acknowledgement.
        }
      }
    }
  }

  Future<void> _cancel() async {
    _cancelled = true;
    final done = _done;
    if (done != null && !done.isCompleted) {
      try {
        await done.future;
      } on Object {
        // The stream's error belongs to the subscriber, not to cancellation.
      }
    }
  }

  Future<void> _writeError(Object error) async {
    final message = error.toString();
    try {
      final log = _log;
      if (log != null) await log.write('ERROR: $message');
    } on Object {
      // A full or removed log must not hide the build error.
    }
  }

  Future<void> _deleteJob() async {
    final job = _job;
    if (job == null) return;
    try {
      await _output.delete(job);
    } on Object {
      // The subscription is already gone; removal is best effort.
    }
  }

  Future<void> _execute() async {
    _check();
    if (!await loadNative()) {
      throw const BuildException(
        "This place does not have flasher_web's native library.",
      );
    }
    final place = await PlaceInfo.current();
    _proxyOta = place.facts.has(Fact.fsOpfs) || place.facts.has(Fact.fsPicker);
    final selectionMap = _map(_req['selection'], 'selection');
    final device = _string(selectionMap['device'], 'Choose a device.');
    final kind = _string(selectionMap['kind'], 'Choose a flasher type.');
    final region = _string(selectionMap['region'], 'Choose a region.');

    final upstreamBase = _string(
      _req['upstreamBase'],
      'Choose an upstream snapshot location.',
    );
    final apiBase = _req['apiBase'] is String ? _req['apiBase'] as String : '';
    final outputStore = _map(_req['output'], 'output');
    _output = await openStore(outputStore);
    final bloatWorkspace = await openStore(_map(_req['bloat'], 'bloat'));
    _transport = HttpCatalogTransport();
    _client = CatalogClient(
      transport: _transport!,
      base: _trailingBase(apiBase),
    );

    final upstream = UpstreamAssets(upstreamBase);
    final tables = await upstream.tables();
    final selection = tables.selection(device, kind, region);
    final builder = selection.builder;
    final needsBase = builder == 'BUILD_ACE6_OOS.sh';
    final zip = _req['zip'] is bool ? _req['zip'] as bool : true;
    final vulnerableAbl = _req['vulnerableAbl'];
    if (selection.dev == 'X9U' && vulnerableAbl is! bool) {
      throw const BuildException(
        'Choose Yes (--vulnerable-abl) or No (--stock-abl) for X9U ABL before '
        'building.',
      );
    }
    if (vulnerableAbl == true && selection.dev != 'X9U') {
      throw const BuildException(
        'The vulnerable ABL option is available only for X9U builds.',
      );
    }
    if (needsBase && !_req.containsKey('base')) {
      throw const BuildException(
        'Ace 6 OxygenOS needs the Ace 6 ColorOS BASE full OTA and the 15R '
        'India TARGET full OTA.',
      );
    }

    final manifestData = await upstream.bloatManifest();
    final bloat = BloatStore(workspace: bloatWorkspace, manifest: manifestData);
    final bloatStatus = await bloat.inspect(selection);
    if (bloatStatus.total > 0 && !bloatStatus.ready) {
      throw BuildException(
        'Local bloat files required: ${bloatStatus.downloaded}/'
        '${bloatStatus.total} verified. Complete step 2 before building.',
      );
    }
    await _logLine('Local bloat files verified: ${bloatStatus.total}');

    final outputFree = await availableStoreBytes(outputStore);
    final outputLocation = outputStore['kind'] == 'opfs'
        ? 'browser storage'
        : 'the output folder';
    if (outputFree != null && outputFree < _gib) {
      throw BuildException('Less than 1 GiB available in $outputLocation.');
    }

    final job = _job = _jobName();
    final log = _log = _BuildLog(_output, '$job/build.log');
    await log.open();
    await _logLine('Job folder: $job');
    await _step(1, 'Prepare OTA');

    final download = '$job/download';
    final sources = <String, _OtaContext>{};
    Map<String, int>? arb;
    _OdmResult? odm;
    var version = '';
    var metadata = const <String, String>{};
    try {
      final roles = needsBase ? const ['ota', 'base'] : const ['ota'];
      for (final role in roles) {
        final prepared = await _prepareOta(role == 'ota' ? 'ota' : 'base');
        sources[role] = prepared;
        if (role == 'ota') {
          version = prepared.archive.version;
          metadata = prepared.archive.fields;
        }
      }
      await _logLine(
        'OTA version: $version; target devices: '
        '${metadata['pre-device'] ?? 'not specified'}',
      );

      var neededBytes = 0;
      for (final role in roles) {
        final source = sources[role]!;
        final selected = needsBase && role == 'ota'
            ? targetParts
            : source.archive.partitions.keys;
        neededBytes +=
            selected.fold<int>(
              0,
              (sum, name) => sum + (source.archive.partitions[name] ?? 0),
            ) *
            (zip ? 3 : 2);
      }
      neededBytes = max(2 * _gib, neededBytes);
      final free = await availableStoreBytes(outputStore);
      if (free != null && free < neededBytes) {
        throw BuildException(
          'Not enough space in $outputLocation: ${_gibText(free)} GiB available; '
          'allow at least ${_gibText(neededBytes)} GiB for this payload. '
          'Choose another output folder.',
        );
      }

      final firmware = needsBase
          ? sources['base']!.archive
          : sources['ota']!.archive;
      try {
        final scanned = await firmware.arb();
        arb = scanned;
      } on CancelledException {
        rethrow;
      } on Object {
        arb = null;
      }
      await _logLine(
        arb == null
            ? 'Anti-rollback (ARB) index: not available for this OTA.'
            : 'Anti-rollback (ARB) index: ${arb['index']}',
      );

      if (needsMatchedOdm(device, kind, region)) {
        _check();
        odm = await _prepareMatchedOdm(
          metadata: metadata,
          targetEntry: sources['ota']!.entry,
          region: region,
          workspace: _output,
          directory: '$download/matched-odm',
        );
      }

      await _step(2, 'Stage flasher and device assets');
      final assetsRoot = '$job/assets';
      await upstream.extractTemplates(
        selection.dev,
        _output,
        '$assetsRoot/flasher_scripts/${selection.dev}',
        check: _check,
      );
      await upstream.extractPlatformTools(
        _output,
        '$assetsRoot/Platform-Tools',
        check: _check,
      );
      final template =
          '$assetsRoot/flasher_scripts/${selection.dev}/'
          '${selection.template}';
      if (!await _output.exists(template)) {
        throw BuildException(
          'The workflow lists this combination, but its template is missing: '
          '${selection.template}',
        );
      }
      if (selection.kind.contains('Hybrid') &&
          !await _output.exists('$template/META-INF')) {
        throw BuildException(
          'Hybrid recovery files are missing: ${selection.template}/META-INF',
        );
      }
      final result = await _stage(
        assetsRoot: assetsRoot,
        template: template,
        bloatWorkspace: bloatWorkspace,
        bloatManifest: manifestData,
        selection: selection,
        job: job,
        check: _check,
      );

      await _step(3, 'Extract partitions and build flasher');
      final hashes = await _buildImages(
        sources: sources,
        needsBase: needsBase,
        result: result,
        download: download,
        selection: selection,
        odmPath: odm?.path,
        check: _check,
      );

      Map<String, Object?>? ablReceipt;
      if (vulnerableAbl == true) {
        ablReceipt = await _packVulnerableAbl(
          workspace: _output,
          bloatWorkspace: bloatWorkspace,
          imageDirectory: '$result/${selection.imageFolder}',
          region: selection.region,
          check: _check,
        );
      }

      final bootImage = '$result/${selection.imageFolder}/boot.img';
      if (!await _output.exists(bootImage)) {
        throw const BuildException(
          'Build output has no boot.img. The OTA may be incomplete or '
          'incompatible.',
        );
      }

      final suffix = selection.region == 'CN' ? 'COS' : selection.region;
      final extension = zip ? '.zip' : '';
      final fileName =
          '${selection.kind} ${selection.dev} $suffix $version$extension';
      final destination = '$job/$fileName';
      await _step(
        4,
        zip ? 'Package ZIP and calculate SHA-256' : 'Finalize flasher folder',
      );
      final package = await packageFlasher(
        _output,
        result,
        destination: destination,
        zip: zip,
        superSize: selection.kind.contains('Super')
            ? tables.superSize(selection.dev, selection.region)
            : null,
        superSizeFile:
            selection.dev == 'X9U' && selection.kind.contains('Super'),
        emit: _emit,
        check: _check,
      );

      _check();
      final manifest = <String, Object?>{
        'device': device,
        'flasher_type': selection.kind,
        'region': selection.region,
        'version': version,
        'artifact': fileName,
        'created': _createdAt(),
        'test_fixture': false,
        'output_format': zip ? 'zip' : 'folder',
        'ota_access': {
          for (final role in sources.keys) role: sources[role]!.access,
        },
        'arb': ?arb,
        if (hashes.isNotEmpty) 'extracted_sha256': hashes,
        'image_sha256': package.imageSha256,
        'odm_source': ?odm?.receipt,
        'abl_source': ?ablReceipt,
      };
      await _writeText(
        _output,
        '$job/build.json',
        '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
      );

      await _logLine('Removing temporary working files…');
      for (final directory in [assetsRoot, '$job/stage', download]) {
        await _output.delete(directory);
      }
      _check();
      await _step(5, 'Complete');
      await _logLine('${zip ? 'ZIP' : 'Folder'}: ${package.artifact}');
      _emit({
        'type': 'result',
        'job': job,
        'artifact': fileName,
        'format': package.format,
        'sha256': package.sha256,
        'manifest': manifest,
      });
    } finally {
      for (final source in sources.values) {
        try {
          await source.archive.close();
        } on Object {
          // The job's result never depends on a closed inspection handle.
        }
      }
    }
  }

  late Workspace _output;

  Future<_OtaContext> _prepareOta(String key) async {
    final input = _map(_req[key], key == 'ota' ? 'OTA' : 'BASE OTA');
    final kind = input['kind'];
    if (kind == 'file') {
      final file = input['file'];
      if (file == null) {
        throw const BuildException(
          'Choose a full OTA file or enter its HTTPS download URL.',
        );
      }
      final source = await openLocalOta(file);
      final OtaArchive archive;
      try {
        archive = await OtaArchive.open(source);
      } on Object {
        await closeByteSource(source);
        rethrow;
      }
      final name = file is String
          ? file.split(RegExp(r'[/\\]')).last
          : 'the OTA';
      await _logLine('Reading $name in place; the OTA is not copied.');
      return _OtaContext(archive: archive, access: 'file');
    }
    if (kind == 'url') {
      final url = input['url'];
      if (url is! String || url.isEmpty) {
        throw const BuildException(
          'Choose a full OTA file or enter its HTTPS download URL.',
        );
      }
      final source = await HttpRangeSource.open(
        _otaUri(url),
        headers: _otaHeaders,
      );
      final OtaArchive archive;
      try {
        archive = await OtaArchive.open(source, remote: true);
      } on Object {
        await closeByteSource(source);
        rethrow;
      }
      final host = Uri.tryParse(url)?.host ?? 'the OTA server';
      await _logLine('Inspecting the OTA on $host using HTTP ranges…');
      await _logLine(
        'Streaming partitions directly from $host; the full OTA ZIP is not '
        'downloaded.',
      );
      return _OtaContext(archive: archive, access: 'stream');
    }
    if (kind != 'catalog') {
      throw const BuildException(
        'Choose a full OTA file or enter its HTTPS download URL.',
      );
    }
    final entry = _releaseEntry(input['entry']);
    await _logLine(
      'Catalog OTA: ${entry['device']} / ${entry['region']} / '
      '${entry['version']}',
    );
    final client = _client!;
    final opened = await _openCatalogEntry(client, entry);
    final size = entry['size'];
    if (size is int && size > 0 && opened.archive.length != size) {
      await opened.archive.close();
      throw const BuildException(
        'The OTA server reports a different file size than the catalog. Fetch '
        'versions again and retry.',
      );
    }
    final host = Uri.tryParse(opened.url)?.host ?? 'the OTA server';
    await _logLine('Inspecting the OTA on $host using HTTP ranges…');
    await _logLine(
      'Streaming partitions directly from $host; the full OTA ZIP is not '
      'downloaded.',
    );
    return _OtaContext(archive: opened.archive, access: 'stream', entry: entry);
  }

  Future<({OtaArchive archive, String url})> _openCatalogEntry(
    CatalogClient client,
    Map<String, dynamic> entry,
  ) async {
    var first = '';
    Future<ByteSource> openFresh() async {
      final url = await client.resolveLink(entry);
      first = url;
      return HttpRangeSource.open(_otaUri(url), headers: _otaHeaders);
    }

    final source = await openFresh();
    final archive = await OtaArchive.open(
      source,
      remote: true,
      refresh: openFresh,
    );
    return (archive: archive, url: first);
  }

  String get _apiBase =>
      _req['apiBase'] is String ? _req['apiBase'] as String : '';

  /// A direct CDN read needs OnePlus's headers; the edge worker adds them.
  Map<String, String> get _otaHeaders => _proxyOta && _apiBase.isNotEmpty
      ? const <String, String>{}
      : otaRequestHeaders;

  Uri _otaUri(String url) => _proxyOta && _apiBase.isNotEmpty
      ? _proxiedOta(_apiBase, url)
      : Uri.parse(url);

  Future<_OdmResult?> _prepareMatchedOdm({
    required Map<String, String> metadata,
    required Map<String, dynamic>? targetEntry,
    required String region,
    required Workspace workspace,
    required String directory,
  }) async {
    final client = _client!;
    final data = await _loadCatalogData();
    final actualTarget = releaseFromMetadata(data, 'OP 15R', region, metadata);
    if (targetEntry != null && targetEntry['id'] != actualTarget['id']) {
      throw const BuildException(
        'The target download returned a different OTA version. ODM matching '
        'stopped.',
      );
    }
    final patch = patchDate(metadata['post-security-patch-level']);
    final target = targetEntry ?? actualTarget;
    if (patch != patchDate(target['security_patch'])) {
      throw const BuildException(
        'The target OTA security patch differs from its catalog entry. The '
        'ODM source cannot be matched safely.',
      );
    }
    final donor = matchingOdm(data, target);
    await _logLine(
      'Matched ODM source: ${donor['device']} / ${donor['region']} / '
      '${donor['version']} / security patch $patch',
    );
    await _logLine('Verifying donor OTA metadata using HTTP ranges…');

    OtaArchive? archive;
    try {
      final opened = await _openCatalogEntry(client, donor);
      final donorArchive = opened.archive;
      archive = donorArchive;
      if (patchDate(donorArchive.fields['post-security-patch-level']) !=
          patch) {
        throw const BuildException(
          'The donor OTA security patch differs from the target. ODM download '
          'stopped.',
        );
      }
      final actualDonor = releaseFromMetadata(
        data,
        'OP ACE 6T',
        'CN',
        donorArchive.fields,
      );
      if (actualDonor['id'] != donor['id']) {
        throw const BuildException(
          'The donor link returned a different OTA version. ODM download '
          'stopped.',
        );
      }
      await _logLine(
        'Downloading ONLY odm.img from the matched OTA; the full Ace 6T OTA '
        'is not downloaded.',
      );
      await extractPartitions(
        donorArchive,
        workspace,
        directory,
        names: const ['odm'],
        emit: _emit,
        check: _check,
      );
      final images = await workspace.list(directory);
      final odm = '$directory/odm.img';
      if (images.length != 1 ||
          images.single != odm ||
          !await workspace.exists(odm) ||
          await workspace.size(odm) <= 0) {
        throw const BuildException(
          'Selective extraction did not produce exactly one non-empty odm.img.',
        );
      }
      final bytes = await workspace.size(odm);
      final digest = await _hashFile(workspace, odm, _check);
      return _OdmResult(
        path: odm,
        receipt: {
          'catalog_id': donor['id'],
          'device': donor['device'],
          'region': donor['region'],
          'version': donor['version'],
          'security_patch': patch,
          'sha256': digest,
          'bytes': bytes,
        },
      );
    } on CancelledException {
      rethrow;
    } on CatalogException {
      rethrow;
    } on BuildException {
      rethrow;
    } on Object catch (error) {
      throw BuildException(
        'Could not verify the ODM source OTA using HTTP ranges. No full-OTA '
        'fallback is used. ($error)',
      );
    } finally {
      if (archive != null) await archive.close();
    }
  }

  Future<Map<String, dynamic>> _loadCatalogData() async {
    final cached = _catalogData;
    if (cached != null) return cached;
    final data = await _client!.loadCatalog();
    _catalogData = data;
    return data;
  }

  Future<String> _stage({
    required String assetsRoot,
    required String template,
    required Workspace bloatWorkspace,
    required BloatManifest bloatManifest,
    required Selection selection,
    required String job,
    required void Function() check,
  }) async {
    final name = selection.kind + (selection.region == 'CN' ? ' CN' : '');
    final result = '$job/stage/$name';
    await _copyTree(_output, template, result, check);
    if (selection.dev == 'X9U' && !selection.kind.contains('Super')) {
      await _output.delete('$result/META-INF');
    }

    final platformTools = '$assetsRoot/Platform-Tools';
    if (await _output.exists(platformTools)) {
      await _copyTree(_output, platformTools, '$result/Platform-Tools', check);
    }
    await _normalizeLineEndings(_output, result, check);

    final main = bloatFolder(selection.dev, selection.kind, selection.region);
    final paths = selectedPaths(bloatManifest.source, selection);
    for (final relative in paths) {
      check();
      final parts = relative.split('/');
      if (parts.length != 4) continue;
      final folder = parts[2];
      final file = parts[3];
      if (selection.dev == 'X9U' && file == 'abl-16.0.6.img') continue;
      final String output;
      if (folder == main) {
        final imageDir = selection.kind.contains('Super')
            ? 'Super'
            : selection.imageFolder;
        output = '$result/$imageDir';
      } else if (folder == 'GLO_BLOAT' && selection.region == 'CN') {
        output = '$result/OOS_FILES_HERE';
      } else {
        output = '$result/COS_FILES_HERE';
      }
      final source = relative.substring('bloat/'.length);
      await _copyAcross(
        bloatWorkspace,
        source,
        _output,
        '$output/$file',
        check,
      );
    }
    return result;
  }

  Future<Map<String, Map<String, String>>> _buildImages({
    required Map<String, _OtaContext> sources,
    required bool needsBase,
    required String result,
    required String download,
    required Selection selection,
    required String? odmPath,
    required void Function() check,
  }) async {
    final ota = sources['ota']!.archive;
    final bootDir = '$result/${selection.imageFolder}';
    final superDir = '$result/Super';
    await _ensureDirectory(_output, bootDir);
    final hashes = <String, Map<String, String>>{};

    if (needsBase) {
      final base = sources['base']!.archive;
      final work = '$download/.ace6_oos_build';
      final baseDir = '$work/BASE';
      final targetDir = '$work/TARGET';
      hashes['base'] = await extractPartitions(
        base,
        _output,
        baseDir,
        emit: _emit,
        check: check,
      );
      hashes['ota'] = await extractPartitions(
        ota,
        _output,
        targetDir,
        names: targetParts,
        emit: _emit,
        check: check,
      );
      await _ensureDirectory(_output, superDir);
      final included = <String>{};
      for (final (directory, parts) in [
        (targetDir, targetParts),
        (baseDir, baseParts),
      ]) {
        for (final name in parts) {
          final image = '$directory/$name.img';
          if (await _output.exists(image)) {
            await _copyFile(_output, image, '$superDir/$name.img', check);
            included.add('$name.img');
          }
        }
      }
      for (final name in const ['vbmeta', 'vbmeta_system', 'vbmeta_vendor']) {
        final image = '$baseDir/$name.img';
        if (!await _output.exists(image)) {
          throw BuildException('Missing BASE $name.img');
        }
        final original = await _readAll(_output, image, check);
        final patched = makeVbmeta(
          includeDescriptorsFrom: [original],
          flags: 3,
          rollbackIndex: BigInt.zero,
        );
        await _writeFile(_output, '$bootDir/$name.img', patched);
        included.add('$name.img');
      }
      for (final image in await _output.list(baseDir)) {
        final name = baseWorkspacePath(image);
        if (included.contains(name)) continue;
        if (!name.endsWith('.img')) continue;
        await _output.move(image, '$bootDir/$name');
      }
      await _output.delete(work);
    } else {
      final available = ota.partitions.keys.toList();
      final wanted = await extractionPlan(
        selection: selection,
        workspace: _output,
        result: result,
        available: available,
      );
      if (wanted != null) {
        await _logLine(
          'Skipping ${available.length - wanted.length} partition(s) this '
          'flasher replaces or discards.',
        );
      }
      final images = '$download/extracted_images';
      hashes['ota'] = await extractPartitions(
        ota,
        _output,
        images,
        names: wanted,
        emit: _emit,
        check: check,
      );
      if (!await _output.exists('$images/boot.img')) {
        throw const BuildException('Full OTA boot.img missing.');
      }
      if (selection.kind.contains('Super')) {
        await _ensureDirectory(_output, superDir);
        if ((selection.dev == 'Ace5' || selection.dev == 'Ace6T') &&
            selection.region != 'CN') {
          await _output.delete('$images/odm.img');
        }
        for (final name
            in selection.dev == 'X9U' ? superParts : extractToSuper) {
          final image = '$images/$name.img';
          if (!await _output.exists(image)) continue;
          final destination = '$superDir/$name.img';
          if (selection.dev == 'X9U' && await _output.exists(destination)) {
            await _output.delete(image);
          } else {
            await _output.move(image, destination);
          }
        }
      }
      for (final image in await _output.list(images)) {
        final name = baseWorkspacePath(image);
        final destination = '$bootDir/$name';
        if (selection.dev == 'X9U' && await _output.exists(destination)) {
          await _output.delete(image);
        } else {
          await _output.move(image, destination);
        }
      }
      await _output.delete(images);
    }

    if (selection.kind.contains('Super')) {
      if (selection.dev == 'Ace6T' &&
          (selection.region == 'IN' || selection.region == 'GLO')) {
        if (odmPath == null || !await _output.exists(odmPath)) {
          throw const BuildException(
            'The patch-matched Ace 6T ODM image is missing. A static ODM will '
            'not be used.',
          );
        }
        check();
        await _copyFile(_output, odmPath, '$superDir/odm.img', check);
      }
      for (final name in _scrapFiles) {
        await _output.delete('$result/$name');
      }
    }
    return hashes;
  }

  Future<Map<String, Object?>?> _packVulnerableAbl({
    required Workspace workspace,
    required Workspace bloatWorkspace,
    required String imageDirectory,
    required String region,
    required void Function() check,
  }) async {
    final folder = bloatFolder('X9U', 'Super Flasher', region);
    final source = 'X9U/$folder/abl-16.0.6.img';
    if (!await bloatWorkspace.exists(source)) {
      throw const BuildException(
        'The X9U ABL 16.0.6 bloat image is missing or has an incorrect '
        'checksum. Complete Download bloat in step 2.',
      );
    }
    final bytes = await bloatWorkspace.size(source);
    final digest = await _hashFile(bloatWorkspace, source, check);
    if (digest.toLowerCase() != _x9uAblSha256) {
      throw const BuildException(
        'The X9U ABL 16.0.6 bloat image is missing or has an incorrect '
        'checksum. Complete Download bloat in step 2.',
      );
    }
    check();
    await _copyAcross(
      bloatWorkspace,
      source,
      workspace,
      '$imageDirectory/abl.img',
      check,
    );
    await _logLine('Packed X9U vulnerable ABL 16.0.6 as abl.img.');
    return {'version': '16.0.6', 'sha256': _x9uAblSha256, 'bytes': bytes};
  }
}

final class _OdmResult {
  const _OdmResult({required this.receipt, required this.path});

  final Map<String, Object?> receipt;
  final String path;
}

final class _OtaContext {
  const _OtaContext({required this.archive, required this.access, this.entry});

  final OtaArchive archive;
  final String access;
  final Map<String, dynamic>? entry;
}

final class _BuildLog {
  _BuildLog(this.workspace, this.path);

  final Workspace workspace;
  final String path;
  ByteSink? _sink;
  int _offset = 0;
  bool _closed = false;

  Future<void> open() async {
    _sink = await workspace.create(path);
  }

  Future<void> write(String text) async {
    final sink = _sink;
    if (sink == null || _closed) return;
    final bytes = Uint8List.fromList(utf8.encode('$text\n'));
    await sink.write(bytes, _offset);
    _offset += bytes.length;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final sink = _sink;
    if (sink != null) {
      try {
        await sink.close();
      } on Object {
        // The build's own error is more useful than a log close failure.
      }
    }
  }
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is! Map) {
    throw BuildException('Missing $field.');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw BuildException('Invalid $field.');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

Map<String, dynamic> _releaseEntry(Object? value) {
  final map = _map(value, 'OTA entry');
  return <String, dynamic>{
    for (final entry in map.entries) entry.key: entry.value,
  };
}

String _string(Object? value, String message) {
  if (value is! String || value.isEmpty) throw BuildException(message);
  return value;
}

Uri _trailingBase(String apiBase) {
  if (apiBase.isEmpty) return Uri.parse('');
  return Uri.parse(apiBase.endsWith('/') ? apiBase : '$apiBase/');
}

Uri _proxiedOta(String apiBase, String url) {
  // Natively there is no CORS proxy to route through; a direct link works.
  if (apiBase.isEmpty) return Uri.parse(url);
  final base = _trailingBase(apiBase);
  final uri = base.resolve('api/ota');
  return uri.replace(queryParameters: {'u': url});
}

String _jobName() {
  final now = DateTime.now();
  final stamp =
      '${now.year.toString().padLeft(4, '0')}'
      '${now.month.toString().padLeft(2, '0')}'
      '${now.day.toString().padLeft(2, '0')}-'
      '${now.hour.toString().padLeft(2, '0')}'
      '${now.minute.toString().padLeft(2, '0')}'
      '${now.second.toString().padLeft(2, '0')}';
  final random = Random.secure().nextInt(1 << 24);
  final suffix = random.toRadixString(16).padLeft(6, '0');
  return '$stamp-$suffix';
}

String _createdAt() {
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${now.year}-${two(now.month)}-${two(now.day)}T'
      '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
}

String _gibText(int bytes) => (bytes / _gib).toStringAsFixed(1);

Future<void> _ensureDirectory(Workspace workspace, String path) async {
  final marker = '$path/.keep';
  final sink = await workspace.create(marker);
  await sink.close();
  await workspace.delete(marker);
}

Future<void> _copyTree(
  Workspace workspace,
  String from,
  String to,
  void Function() check,
) async {
  final files = await workspace.list(from, recursive: true);
  for (final file in files) {
    check();
    final suffix = file.substring(from.length + 1);
    await _copyFile(workspace, file, '$to/$suffix', check);
  }
}

/// Copies a file between two workspaces, such as the bloat store and the job.
Future<void> _copyAcross(
  Workspace fromWorkspace,
  String from,
  Workspace toWorkspace,
  String to,
  void Function() check,
) async {
  final source = await fromWorkspace.open(from);
  final sink = await toWorkspace.create(to);
  var offset = 0;
  var failed = true;
  try {
    while (offset < source.length) {
      check();
      final length = source.length - offset < _chunk
          ? source.length - offset
          : _chunk;
      await sink.write(await source.read(offset, length), offset);
      offset += length;
    }
    failed = false;
  } finally {
    await closeByteSource(source);
    await sink.close();
    if (failed) {
      try {
        await toWorkspace.delete(to);
      } on Object {
        // A partial copy in a failed job is diagnosed by its caller.
      }
    }
  }
}

Future<void> _copyFile(
  Workspace workspace,
  String from,
  String to,
  void Function() check,
) async {
  final source = await workspace.open(from);
  ByteSink? sink;
  var failed = true;
  try {
    final target = await workspace.create(to);
    sink = target;
    var offset = 0;
    while (offset < source.length) {
      check();
      final length = source.length - offset < _chunk
          ? source.length - offset
          : _chunk;
      await target.write(await source.read(offset, length), offset);
      offset += length;
    }
    failed = false;
  } finally {
    await closeByteSource(source);
    final targetSink = sink;
    if (targetSink != null) await targetSink.close();
    if (failed && sink != null) {
      try {
        await workspace.delete(to);
      } on Object {
        // A partial copy in a failed job is diagnosed by its caller.
      }
    }
  }
}

Future<Uint8List> _readAll(
  Workspace workspace,
  String path,
  void Function() check,
) async {
  final source = await workspace.open(path);
  try {
    final builder = BytesBuilder(copy: false);
    var offset = 0;
    while (offset < source.length) {
      check();
      final length = source.length - offset < _chunk
          ? source.length - offset
          : _chunk;
      builder.add(await source.read(offset, length));
      offset += length;
    }
    return builder.takeBytes();
  } finally {
    await closeByteSource(source);
  }
}

Future<void> _writeFile(
  Workspace workspace,
  String path,
  List<int> bytes,
) async {
  final sink = await workspace.create(path);
  try {
    final data = Uint8List.fromList(bytes);
    await sink.write(data, 0);
    await sink.truncate(data.length);
  } finally {
    await sink.close();
  }
}

Future<void> _writeText(Workspace workspace, String path, String text) =>
    _writeFile(workspace, path, utf8.encode(text));

Future<String> _hashFile(
  Workspace workspace,
  String path,
  void Function() check,
) async {
  final source = await workspace.open(path);
  try {
    final hasher = Sha256Hasher();
    var offset = 0;
    while (offset < source.length) {
      check();
      final length = source.length - offset < _chunk
          ? source.length - offset
          : _chunk;
      hasher.update(bytes: await source.read(offset, length));
      offset += length;
    }
    return hasher.finishHex();
  } finally {
    await closeByteSource(source);
  }
}

Future<void> _normalizeLineEndings(
  Workspace workspace,
  String result,
  void Function() check,
) async {
  final files = await workspace.list(result, recursive: true);
  for (final path in files) {
    final name = baseWorkspacePath(path);
    if (name != 'updater-script' && !name.endsWith('.sh')) continue;
    check();
    final bytes = await _readAll(workspace, path, check);
    final normalized = BytesBuilder(copy: false);
    var changed = false;
    for (var index = 0; index < bytes.length; index++) {
      final byte = bytes[index];
      if (byte == 0x0d &&
          index + 1 < bytes.length &&
          bytes[index + 1] == 0x0a) {
        changed = true;
        continue;
      }
      normalized.addByte(byte);
    }
    if (changed) await _writeFile(workspace, path, normalized.takeBytes());
  }
}
