import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

import '../api/platform_bridge.dart';
import '../format.dart';
import '../preferences.dart';
import '../runtime.dart';

/// Which OTA source step 3 shows.
enum OtaMode { localFile, catalog }

/// Which of the two stores a page-side button changes.
enum StoreTarget { bloat, output }

/// A store the pipeline can open, chosen from facts plus a page-side pick.
final class StoreChoice {
  const StoreChoice.browser() : directory = null;

  const StoreChoice.folder(DirectoryRef this.directory);

  final DirectoryRef? directory;

  bool get isFolder => directory != null;

  String get name => directory?.name ?? 'Browser storage';

  Map<String, Object?> toService() => directory == null
      ? const {'kind': 'opfs'}
      : {'kind': 'directory', 'handle': directory!.handle};
}

/// The New package form: selection, bloat, OTA, ABL, output and gating.
///
/// Gating texts are ports of upstream `build_requirements_error`,
/// `update_summary` and `odm_catalog_error`.
final class SetupState extends ChangeNotifier {
  static final _log = Logger('ui.setup');

  SetupState({
    required this.runtime,
    required this.tables,
    required this.environment,
    required this.preferences,
  }) {
    _device = _initialDevice();
    _kind = _initialKind();
    _region = _initialRegion();
    _zipOutput = preferences.zipOutput;
    _dropSubscription = runtime.bridge.droppedFiles.listen((file) {
      unawaited(setLocalFile('ota', file));
    });
    _launchSubscription = runtime.bridge.launchedFiles.listen((file) {
      // A file opened with the installed PWA is the same local OTA choice as
      // a dropped file.
      unawaited(setLocalFile('ota', file));
    });
    unawaited(_restoreStores());
    unawaited(_restoreOtaFile());
    unawaited(refreshBloat());
    unawaited(refreshBudget());
  }

  final AppRuntime runtime;
  final UpstreamTables tables;
  final EnvironmentInfo environment;
  final SetupPreferences preferences;

  late String _device;
  late String _kind;
  late String _region;
  late bool _zipOutput;
  bool? _vulnerableAbl;

  OtaMode _otaMode = OtaMode.localFile;
  bool _hostedBuild = false;

  StoreChoice _bloatStore = const StoreChoice.browser();
  StoreChoice _outputStore = const StoreChoice.browser();
  final _pendingFolder = <StoreTarget, String>{};
  String? _storeError;

  final _localFiles = <String, PickedFile>{};
  final _inspections = <String, Map<String, Object?>>{};
  final _inspectionErrors = <String, String>{};
  final _inspecting = <String>{};

  Map<String, Object?>? _bloatData;
  String? _bloatDataKey;
  bool _bloatChecking = false;
  String? _bloatError;
  int _bloatToken = 0;
  StreamSubscription<Map<String, Object?>>? _bloatSubscription;
  bool _bloatDownloading = false;
  bool _bloatAwake = false;
  String? _bloatDownloadError;
  final _bloatLog = <String>[];
  final _bloatProgress = <String, ({int done, int total})>{};

  Map<String, dynamic>? _catalogData;
  bool _catalogLoading = false;
  String? _catalogError;
  final _catalogReleases = <String, List<Map<String, dynamic>>>{};
  final _selectedReleases = <String, Map<String, dynamic>>{};
  String? _odmDonor;
  String? _odmError;

  StreamSubscription<PickedFile>? _dropSubscription;
  StreamSubscription<PickedFile>? _launchSubscription;
  bool _disposed = false;

  String? _pendingOtaName;

  Map<String, Object?>? _budget;
  bool _budgetLoading = false;
  String? _budgetError;
  bool _cachingOta = false;
  String? _cacheOtaError;
  String? _cachingKey;
  int _cacheToken = 0;
  StreamSubscription<Map<String, Object?>>? _cacheSubscription;
  final _cacheProgress = <String, ({int done, int total})>{};

  String get device => _device;
  String get kind => _kind;
  String get region => _region;
  bool get zipOutput => _zipOutput;
  bool? get vulnerableAbl => _vulnerableAbl;
  OtaMode get otaMode => _otaMode;
  bool get hostedBuild => _hostedBuild;

  /// Hosted builds exist only for catalog sources with mapped releases.
  bool get hostedAvailable {
    if (_otaMode != OtaMode.catalog || !selectionValid) return false;
    try {
      return otaCatalogTargets(_device, _kind, _region).isNotEmpty;
    } on CatalogException {
      return false;
    }
  }
  StoreChoice get bloatStore => _bloatStore;
  StoreChoice get outputStore => _outputStore;
  bool get pickerAvailable =>
      runtime.bridge.canPickDirectory && environment.storage.handle;
  bool get opfsAvailable => environment.storage.opfs;
  bool get isX9U => _device == 'OPPO Find X9 Ultra';
  bool get needsBase =>
      _device == 'Oneplus Ace 6' &&
      _kind == 'SuperHybrid Flasher' &&
      _region == 'IN';
  bool get needsMatchedOdm =>
      fileOtaCatalogNeedsMatchedOdm(_device, _kind, _region);

  List<String> get kinds => tables.types(_device);
  List<String> get regions => tables.regions(_device, _kind);

  Selection? get selection {
    try {
      return tables.selection(_device, _kind, _region);
    } on UpstreamException {
      return null;
    }
  }

  bool get selectionValid => selection != null;

  Map<String, Object?>? get selectionMap {
    if (!selectionValid) return null;
    return {'device': _device, 'kind': _kind, 'region': _region};
  }

  String get deviceDisplay => _device.replaceFirst('Oneplus', 'OnePlus');

  String get osLabel =>
      (selection?.coloros ?? false) ? 'COLOR OS' : 'OXYGEN OS';

  String get osName => (selection?.coloros ?? false) ? 'ColorOS' : 'OxygenOS';

  String get regionDisplay => _region == 'GLO' ? 'Global' : _region;

  String get workflowHint => isX9U
      ? 'CONFIGURE → BLOAT FILES → OTA → ABL → BUILD'
      : 'CONFIGURE → BLOAT FILES → OTA → BUILD';

  /// Step 2's one-line summary under the fields.
  String get selectionInfo {
    if (!selectionValid) {
      return 'This device, flasher type and region combination is unsupported.';
    }
    if (needsBase) {
      return 'Target: OnePlus 15R India OxygenOS OTA · '
          'Base: Ace 6 ColorOS OTA';
    }
    if (isX9U) {
      return _region == 'CN'
          ? 'ColorOS · EU bloat is used for CN.'
          : 'ColorOS · $_region bloat files.';
    }
    if (needsMatchedOdm) {
      return 'Target: OnePlus 15R · ODM: Ace 6T CN · '
          'Exact patch match required.';
    }
    return 'Only combinations supported by the build workflow are available.';
  }

  String get sourceHint {
    if (_hostedBuild) {
      return 'The server builds from these catalog release IDs. No local file '
          'or custom URL is uploaded.';
    }
    if (needsMatchedOdm) {
      return 'Only odm.img is streamed; the donor must have the same '
          'security patch.';
    }
    if (_otaMode == OtaMode.catalog) {
      return 'Choose a version to download or build. Temporary links are '
          'refreshed automatically.';
    }
    return 'Use a full OTA package. Incremental updates are not supported.';
  }

  // ---------------------------------------------------------------- selection

  String _initialDevice() {
    final saved = preferences.device;
    if (saved != null && tables.devices.containsKey(saved)) return saved;
    return tables.devices.keys.first;
  }

  String _initialKind() {
    final available = tables.types(_device);
    final saved = preferences.kind;
    if (saved != null && available.contains(saved)) return saved;
    return available.first;
  }

  String _initialRegion() {
    final available = tables.regions(_device, _kind);
    final saved = preferences.region;
    if (saved != null && available.contains(saved)) return saved;
    return available.first;
  }

  void selectDevice(String value) {
    if (value == _device) return;
    _device = value;
    final availableKinds = tables.types(value);
    if (!availableKinds.contains(_kind)) _kind = availableKinds.first;
    final availableRegions = tables.regions(value, _kind);
    if (!availableRegions.contains(_region)) _region = availableRegions.first;
    _vulnerableAbl = null;
    _afterSelectionChange();
  }

  void selectKind(String value) {
    if (value == _kind) return;
    _kind = value;
    final available = tables.regions(_device, value);
    if (!available.contains(_region)) _region = available.first;
    _afterSelectionChange();
  }

  void selectRegion(String value) {
    if (value == _region) return;
    _region = value;
    _afterSelectionChange();
  }

  void setVulnerableAbl(bool? value) {
    if (_vulnerableAbl == value) return;
    _vulnerableAbl = value;
    _savePreferences();
    _notify();
  }

  void setZipOutput(bool value) {
    if (_zipOutput == value) return;
    _zipOutput = value;
    _savePreferences();
    _notify();
  }

  void setOtaMode(OtaMode mode) {
    if (_otaMode == mode) return;
    _otaMode = mode;
    if (mode != OtaMode.catalog) _hostedBuild = false;
    _notify();
    if (mode == OtaMode.catalog && _catalogData == null && !_catalogLoading) {
      unawaited(fetchCatalog());
    }
  }

  /// Selects server-side building for catalog releases only.
  ///
  /// A local file or URL source can never turn this on; switching back to a
  /// local file clears it so no stale hosted choice survives.
  void setHostedBuild(bool value) {
    if (value) {
      if (!hostedAvailable) return;
      if (_hostedBuild) return;
      _hostedBuild = true;
      _notify();
      if (_catalogData == null && !_catalogLoading) {
        unawaited(fetchCatalog());
      }
      return;
    }
    if (!_hostedBuild) return;
    _hostedBuild = false;
    _notify();
  }

  void _afterSelectionChange() {
    _populateCatalog();
    if (_hostedBuild && !hostedAvailable) _hostedBuild = false;
    _notify();
    _savePreferences();
    unawaited(refreshBloat());
    if (_otaMode == OtaMode.catalog && _catalogData == null) {
      unawaited(fetchCatalog());
    }
  }

  // -------------------------------------------------------------------- bloat

  String get _bloatKey =>
      '$_device|$_kind|$_region|${_bloatStore.isFolder ? _bloatStore.name : 'opfs'}';

  bool get bloatChecking => _bloatChecking;
  String? get bloatError => _bloatDownloadError ?? _bloatError;
  Map<String, Object?>? get bloatData => _bloatData;
  bool get bloatDownloading => _bloatDownloading;
  List<String> get bloatLog => List.unmodifiable(_bloatLog);
  Map<String, ({int done, int total})> get bloatProgress =>
      Map.unmodifiable(_bloatProgress);

  bool get bloatReady {
    final data = _bloatData;
    return selectionValid &&
        _bloatError == null &&
        data != null &&
        _bloatDataKey == _bloatKey &&
        (data['ready'] == true || (data['total'] as num? ?? 0) == 0);
  }

  int get bloatTotal => (_bloatData?['total'] as num? ?? 0).toInt();
  int get bloatDownloaded => (_bloatData?['downloaded'] as num? ?? 0).toInt();
  int get bloatBytes => (_bloatData?['bytes'] as num? ?? 0).toInt();

  String get bloatStatusText {
    if (!selectionValid) return 'Selection unavailable';
    if (_bloatError != null) return 'Could not check local files';
    if (_bloatChecking || _bloatData == null) return 'Checking local files…';
    if (bloatTotal == 0) return 'No extra bloat needed';
    if (bloatReady) return 'Already downloaded';
    if (bloatDownloaded > 0) {
      return '$bloatDownloaded of $bloatTotal files downloaded';
    }
    return 'Not downloaded';
  }

  String get bloatInfo {
    if (_bloatError != null) return _bloatError!;
    final data = _bloatData;
    if (data == null) return 'For the selected device and region';
    final total = bloatTotal;
    final size = formatBytes(bloatBytes);
    return bloatReady
        ? '$total verified images · $size'
        : '$total images · $size total';
  }

  String get bloatButtonLabel {
    if (bloatTotal == 0) return 'No download needed';
    if (bloatReady) return 'Already downloaded';
    if (bloatDownloaded > 0) return 'Download missing bloat';
    return 'Download bloat';
  }

  bool get canDownloadBloat =>
      selectionValid &&
      !_bloatChecking &&
      !_bloatDownloading &&
      _bloatData != null &&
      bloatTotal > 0 &&
      !bloatReady;

  Future<void> refreshBloat({bool force = true}) async {
    if (!selectionValid) {
      _bloatData = null;
      _bloatDataKey = null;
      _bloatChecking = false;
      _notify();
      return;
    }
    final selectionValue = selectionMap!;
    final key = _bloatKey;
    final token = ++_bloatToken;
    _bloatChecking = true;
    _bloatError = null;
    _notify();
    try {
      final data = await runtime.service.bloatStatus({
        'selection': selectionValue,
        'store': _bloatStore.toService(),
        'upstreamBase': runtime.upstreamBase,
      });
      if (_disposed || token != _bloatToken) return;
      _bloatData = data;
      _bloatDataKey = key;
    } on Object catch (error) {
      if (_disposed || token != _bloatToken) return;
      _bloatData = null;
      _bloatDataKey = null;
      _bloatError = '$error';
    } finally {
      if (!_disposed && token == _bloatToken) {
        _bloatChecking = false;
        _notify();
      }
    }
  }

  Future<void> downloadBloat() async {
    _log.info(
      'downloadBloat pressed can=$canDownloadBloat total=$bloatTotal '
      'checking=$_bloatChecking downloading=$_bloatDownloading ready=$bloatReady',
    );
    if (!canDownloadBloat || selectionMap == null) return;
    _bloatDownloading = true;
    _bloatError = null;
    _bloatDownloadError = null;
    _bloatLog.clear();
    _bloatProgress.clear();
    _notify();
    _log.info('downloadBloat state is downloading');
    _bloatAwake = true;
    try {
      await runtime.bridge.beginKeepAwake();
      _log.info('downloadBloat keep awake done');
    } catch (error) {
      _log.warning('downloadBloat keep awake failed', error);
    }
    final request = {
      'selection': selectionMap!,
      'store': _bloatStore.toService(),
      'upstreamBase': runtime.upstreamBase,
      'apiBase': runtime.apiBase,
    };
    _log.info('downloadBloat subscribing');
    _bloatSubscription = runtime.service
        .downloadBloat(request)
        .listen(
          (event) {
            switch (event['type']) {
              case 'log':
                final text = event['text'];
                if (text is String) _bloatLog.add(text);
              case 'progress':
                final label = event['label'];
                final done = event['done'];
                final total = event['total'];
                if (label is String && done is num && total is num) {
                  _bloatProgress[label] = (
                    done: done.toInt(),
                    total: total.toInt(),
                  );
                }
              case 'result':
                final bloat = event['bloat'];
                if (bloat is Map) {
                  _bloatData = Map<String, Object?>.from(bloat);
                  _bloatDataKey = _bloatKey;
                  _bloatDownloadError = null;
                }
              default:
                break;
            }
            _notify();
          },
          onError: (Object error) {
            _log.warning('downloadBloat stream error', error);
            _bloatDownloadError = 'Bloat download failed: $error';
            _bloatLog.add('ERROR: $error');
            unawaited(_finishBloat());
          },
          onDone: () {
            _log.info('downloadBloat stream done');
            unawaited(_finishBloat());
          },
          cancelOnError: false,
        );
  }

  void cancelBloat() {
    if (!_bloatDownloading) return;
    _bloatLog.add('Download cancelled.');
    unawaited(_bloatSubscription?.cancel());
    _bloatSubscription = null;
    unawaited(_finishBloat());
  }

  Future<void> _finishBloat() async {
    if (!_bloatDownloading && !_bloatAwake) return;
    _bloatDownloading = false;
    _bloatSubscription = null;
    if (_bloatAwake) {
      _bloatAwake = false;
      try {
        await runtime.bridge.endKeepAwake();
      } catch (_) {
        // Best effort.
      }
    }
    _notify();
    unawaited(refreshBloat());
  }

  // --------------------------------------------------------------------- OTA

  PickedFile? localFile(String role) => _localFiles[role];

  Map<String, Object?>? inspection(String role) => _inspections[role];

  String? inspectionError(String role) => _inspectionErrors[role];

  bool inspecting(String role) => _inspecting.contains(role);

  Future<void> pickLocalFile(String role) async {
    final file = await runtime.bridge.pickOtaFile();
    if (file == null) return;
    await setLocalFile(role, file);
  }

  Future<void> setLocalFile(String role, PickedFile file) async {
    _localFiles[role] = file;
    _inspections.remove(role);
    _inspectionErrors.remove(role);
    if (_otaMode != OtaMode.localFile) {
      _otaMode = OtaMode.localFile;
    }
    _hostedBuild = false;
    _notify();
    await _inspect(role);
  }

  void clearLocalFile(String role) {
    _localFiles.remove(role);
    _inspections.remove(role);
    _inspectionErrors.remove(role);
    _notify();
  }

  /// The name of a remembered local OTA whose read permission must be renewed.
  String? get pendingOtaName => _pendingOtaName;

  /// Reopens the remembered OTA. The browser prompts for read permission, so
  /// call this from the click handler.
  Future<void> reconnectOtaFile() async {
    try {
      final file = await runtime.bridge.requestRememberedOtaFile();
      if (_disposed) return;
      if (file == null) {
        _inspectionErrors['ota'] =
            'The browser did not grant read access to the remembered OTA. '
            'Choose it again.';
        _notify();
        return;
      }
      _pendingOtaName = null;
      await setLocalFile('ota', file);
    } on Object catch (error) {
      _inspectionErrors['ota'] = '$error';
      _notify();
    }
  }

  Future<void> _restoreOtaFile() async {
    try {
      final file = await runtime.bridge.rememberedOtaFile();
      if (_disposed) return;
      if (file != null) {
        _pendingOtaName = null;
        await setLocalFile('ota', file);
        return;
      }
      final name = await runtime.bridge.rememberedOtaFileName();
      if (_disposed) return;
      if (name != null && name.isNotEmpty) {
        _pendingOtaName = name;
        _notify();
      }
    } on Object {
      // The remembered handle is optional: a missing browser store only means
      // the OTA is picked again.
    }
  }

  Future<void> _inspect(String role) async {
    final file = _localFiles[role];
    if (file == null || !_inspecting.add(role)) return;
    _notify();
    try {
      final result = await runtime.service.inspectOta({
        'ota': {'kind': 'file', 'file': file.handle},
        'apiBase': runtime.apiBase,
      });
      _inspections[role] = result;
      _inspectionErrors.remove(role);
    } on Object catch (error) {
      _inspectionErrors[role] = '$error';
      _inspections.remove(role);
    } finally {
      _inspecting.remove(role);
      _notify();
    }
  }

  Map<String, Object?>? otaInput(String role) {
    if (_otaMode == OtaMode.catalog) {
      final entry = _selectedReleases[role];
      return entry == null ? null : {'kind': 'catalog', 'entry': entry};
    }
    final file = _localFiles[role];
    return file == null ? null : {'kind': 'file', 'file': file.handle};
  }

  // ----------------------------------------------------------------- catalog

  bool get catalogLoading => _catalogLoading;
  String? get catalogError => _catalogError;
  Map<String, dynamic>? get catalogData => _catalogData;
  String? get odmDonor => _odmDonor;
  String? get odmError => _odmError;

  List<Map<String, dynamic>> releasesForRole(String role) =>
      List.unmodifiable(_catalogReleases[role] ?? const []);

  Map<String, dynamic>? selectedRelease(String role) => _selectedReleases[role];

  Map<String, ({String device, String region})> get _targets {
    if (!selectionValid) return const {};
    try {
      return otaCatalogTargets(_device, _kind, _region);
    } on CatalogException {
      return const {};
    }
  }

  String get catalogStatusText {
    if (_catalogLoading) return 'Fetching available versions…';
    if (_catalogError != null) return _catalogError!;
    if (_catalogData == null) {
      return 'Fetch available full OTA versions for your device and region.';
    }
    final counts = <String>[];
    for (final role in const ['ota', 'base']) {
      final target = _targets[role];
      if (target == null) continue;
      counts.add(
        '${target.device} / ${target.region}: '
        '${(_catalogReleases[role] ?? const []).length} versions',
      );
    }
    if (counts.isEmpty) {
      return 'Fetch available full OTA versions for your device and region.';
    }
    final stale = _catalogData?['_stale'] == true
        ? 'Offline · cached versions · '
        : '';
    return '$stale${counts.join(' · ')}';
  }

  Future<void> fetchCatalog({bool force = true}) async {
    if (_catalogLoading || !selectionValid) return;
    _catalogLoading = true;
    _catalogError = null;
    _notify();
    try {
      final data = await runtime.loadCatalog(force: force);
      _catalogData = data;
      _populateCatalog();
    } on Object catch (error) {
      _catalogError = '$error';
      _catalogReleases.clear();
      _selectedReleases.clear();
      _refreshOdm();
    } finally {
      _catalogLoading = false;
      _notify();
    }
  }

  void selectCatalogRelease(String role, String id) {
    final entries = _catalogReleases[role] ?? const [];
    Map<String, dynamic>? found;
    for (final entry in entries) {
      if (entry['id'] == id) {
        found = entry;
        break;
      }
    }
    if (found == null) return;
    _selectedReleases[role] = found;
    _refreshOdm();
    _notify();
  }

  void _populateCatalog() {
    final previous = Map<String, Map<String, dynamic>>.from(_selectedReleases);
    _catalogReleases.clear();
    _selectedReleases.clear();
    final data = _catalogData;
    if (data == null || !selectionValid) {
      _refreshOdm();
      return;
    }
    for (final role in const ['ota', 'base']) {
      final target = _targets[role];
      if (target == null) continue;
      final entries = otaCatalogReleasesFor(data, target.device, target.region);
      _catalogReleases[role] = entries;
      if (entries.isEmpty) continue;
      final previousId = previous[role]?['id'];
      Map<String, dynamic>? match;
      if (previousId != null) {
        for (final entry in entries) {
          if (entry['id'] == previousId) {
            match = entry;
            break;
          }
        }
      }
      _selectedReleases[role] = match ?? entries.first;
    }
    _refreshOdm();
  }

  void _refreshOdm() {
    _odmDonor = null;
    _odmError = null;
    if (!needsMatchedOdm) return;
    final entry = _selectedReleases['ota'];
    final data = _catalogData;
    if (entry == null || data == null) return;
    try {
      final donor = otaCatalogMatchingOdm(
        data,
        Map<String, dynamic>.from(entry),
      );
      _odmDonor = donor['version'] as String?;
    } on CatalogException catch (error) {
      _odmError = error.message;
    }
  }

  String catalogDetail(String role) {
    final entry = _selectedReleases[role];
    if (entry == null) {
      return 'No version selected. Fetch versions or use a local file.';
    }
    final details = <String>[
      '${entry['device']} / ${entry['region']}',
      if (entry['model'] is String && (entry['model']! as String).isNotEmpty)
        entry['model']! as String,
      if (entry['size'] is num)
        '${((entry['size']! as num).toDouble() / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB',
      if (entry['security_patch'] is String) 'Patch ${entry['security_patch']}',
      if (entry['package_type'] == 'reconstructed_full')
        'Reconstructed full package',
    ];
    if (role == 'ota' && needsMatchedOdm) {
      if (_odmDonor != null) {
        details.add('ODM only: $_odmDonor');
      } else if (_odmError != null) {
        details.add('ODM unavailable: no exact patch match.');
      }
    }
    return details.join(' · ');
  }

  String? get selectedVersion {
    if (_otaMode == OtaMode.localFile) {
      final version = _inspections['ota']?['version'];
      return version is String ? version : null;
    }
    final version = _selectedReleases['ota']?['version'];
    return version is String ? version : null;
  }

  Map<String, Object?> get packageSummary => {
    'device': deviceDisplay,
    'kind': _kind,
    'os': osName,
    'region': regionDisplay,
    'format': _hostedBuild
        ? 'Hosted ZIP + SHA-256'
        : (_zipOutput ? 'ZIP + SHA-256' : 'Flasher folder'),
    'engine': _hostedBuild
        ? 'Hosted builder'
        : (environment.native ? 'Rust / WebAssembly' : 'Dart worker'),
    'version': selectedVersion ?? '—',
  };

  // ------------------------------------------------------------------ output

  bool get canChangeStores => !_bloatDownloading;

  String? pendingFolderName(StoreTarget target) => _pendingFolder[target];

  String? get storeError => _storeError;

  Future<void> chooseFolder(StoreTarget target) async {
    final key = target == StoreTarget.bloat ? 'bloat' : 'output';
    final label = target == StoreTarget.bloat
        ? 'Choose bloat download folder'
        : 'Build output folder';
    try {
      final ref = await runtime.bridge.pickDirectory(key, label: label);
      if (ref == null) return;
      _pendingFolder.remove(target);
      _storeError = null;
      _setStore(target, StoreChoice.folder(ref));
    } on Object catch (error) {
      _storeError = '$error';
      _notify();
    }
  }

  Future<void> reconnectFolder(StoreTarget target) async {
    final key = target == StoreTarget.bloat ? 'bloat' : 'output';
    try {
      final ref = await runtime.bridge.requestRememberedDirectory(key);
      if (ref == null) return;
      _pendingFolder.remove(target);
      _setStore(target, StoreChoice.folder(ref));
    } on Object catch (error) {
      _bloatError = '$error';
      _notify();
    }
  }

  void useBrowserStorage(StoreTarget target) {
    _pendingFolder.remove(target);
    _setStore(target, const StoreChoice.browser());
  }

  void _setStore(StoreTarget target, StoreChoice choice) {
    if (target == StoreTarget.bloat) {
      _bloatStore = choice;
      unawaited(refreshBloat());
      unawaited(refreshBudget());
    } else {
      _outputStore = choice;
    }
    _notify();
  }

  Future<void> _restoreStores() async {
    if (!pickerAvailable) return;
    for (final target in StoreTarget.values) {
      final key = target == StoreTarget.bloat ? 'bloat' : 'output';
      try {
        final ref = await runtime.bridge.rememberedDirectory(key);
        if (_disposed) return;
        if (ref != null) {
          _setStore(target, StoreChoice.folder(ref));
          continue;
        }
        final name = await runtime.bridge.rememberedDirectoryName(key);
        if (_disposed) return;
        if (name != null) _pendingFolder[target] = name;
      } on Object {
        // A missing or unreadable handle simply leaves the default store.
      }
    }
    _notify();
  }

  // ------------------------------------------------------------------ gating

  /// Port of upstream `build_requirements_error`, plus the hosted rules.
  String get buildRequirementsError {
    if (!selectionValid) {
      return 'Choose a supported device, flasher type and region.';
    }
    if (isX9U && _vulnerableAbl == null) {
      return 'Step 4: choose Yes or No for vulnerable ABL before building.';
    }
    if (_hostedBuild) {
      if (_otaMode != OtaMode.catalog) {
        return 'Hosted builds require Version catalog as the OTA source.';
      }
      final roles = _targets.keys.toList();
      if (roles.isEmpty) {
        return 'This device has no catalog target for a hosted build.';
      }
      for (final role in roles) {
        final entry = _selectedReleases[role];
        final id = entry?['id'];
        if (id is! String || id.isEmpty) {
          final title = role == 'ota' ? 'TARGET' : 'BASE';
          return 'Select a full $title OTA catalog version for the hosted '
              'build.';
        }
      }
      if (needsMatchedOdm) {
        if (_selectedReleases['ota'] == null) {
          return 'Select a target OTA with a matching Ace 6T security patch.';
        }
        if (_odmError != null) return _odmError!;
      }
      return '';
    }
    if (!bloatReady) {
      return 'Required bloat files must be downloaded and verified before '
          'building.';
    }
    final roles = _targets.keys.toList();
    for (final role in roles) {
      final title = role == 'ota' ? 'TARGET' : 'BASE';
      if (_otaMode == OtaMode.catalog) {
        if (_selectedReleases[role] == null) {
          return 'Select a full $title OTA ZIP, download URL or catalog '
              'version.';
        }
      } else if (_localFiles[role] == null) {
        return 'Select a full $title OTA ZIP, download URL or catalog version.';
      }
    }
    if (_otaMode == OtaMode.catalog && needsMatchedOdm) {
      if (_selectedReleases['ota'] == null) {
        return 'Select a target OTA with a matching Ace 6T security patch.';
      }
      if (_odmError != null) return _odmError!;
    }
    if (_outputStore.isFolder && _outputStore.directory == null) {
      return 'Choose an output folder.';
    }
    return '';
  }

  bool get canBuild =>
      buildRequirementsError.isEmpty &&
      (_hostedBuild || !_bloatDownloading) &&
      !catalogLoading;

  /// The catalog-only request sent to the hosted builder.
  ///
  /// Null unless hosted mode is valid; unknown fields, local files and URLs
  /// are never included.
  Map<String, Object?>? hostedBuildRequest() {
    if (!_hostedBuild || !canBuild) return null;
    final target = _selectedReleases['ota'];
    final catalogId = target?['id'];
    if (catalogId is! String || catalogId.isEmpty) return null;
    String? baseCatalogId;
    if (needsBase) {
      final baseId = _selectedReleases['base']?['id'];
      if (baseId is! String || baseId.isEmpty) return null;
      baseCatalogId = baseId;
    }
    return {
      'hosted': true,
      'selection': selectionMap!,
      'catalogId': catalogId,
      'baseCatalogId': ?baseCatalogId,
      if (isX9U && _vulnerableAbl != null) 'vulnerableAbl': _vulnerableAbl,
    };
  }

  Map<String, Object?>? buildRequest() {
    if (!canBuild) return null;
    if (_hostedBuild) return hostedBuildRequest();
    final ota = otaInput('ota');
    if (ota == null) return null;
    final base = needsBase ? otaInput('base') : null;
    return {
      'selection': selectionMap!,
      'ota': ota,
      'base': ?base,
      if (isX9U && _vulnerableAbl != null) 'vulnerableAbl': _vulnerableAbl,
      'zip': _zipOutput,
      'bloat': _bloatStore.toService(),
      'output': _outputStore.toService(),
      'apiBase': runtime.apiBase,
      'upstreamBase': runtime.upstreamBase,
    };
  }

  // ----------------------------------------------------------- direct flash

  /// Super kinds build a super partition image set and cannot be flashed from
  /// the OTA bytes alone.
  bool get isSuperKind => _kind.contains('Super');

  bool get directFlashSupported =>
      selectionValid &&
      (_kind == 'Regional Flasher' || _kind == 'RegionalHybrid Flasher');

  /// Why Flash directly is not offered for this selection.
  String get directFlashUnavailable {
    if (!selectionValid) {
      return 'Choose a supported device, flasher type and region.';
    }
    if (isSuperKind) {
      return '$_kind needs a built package: Super kinds fold the OTA into a '
          'super partition image set. Flash directly is offered for Regional '
          'Flasher and RegionalHybrid Flasher selections.';
    }
    return '$_kind has no direct flash path. Flash directly is offered for '
        'Regional Flasher and RegionalHybrid Flasher selections.';
  }

  /// Port of the direct-flash prerequisites: verified bloat and one OTA.
  String get directFlashRequirementsError {
    if (!directFlashSupported) return directFlashUnavailable;
    if (!bloatReady) {
      return 'Required bloat files must be downloaded and verified before '
          'flashing directly.';
    }
    if (_otaMode == OtaMode.catalog) {
      if (_selectedReleases['ota'] == null) {
        return 'Select a full TARGET OTA catalog version before flashing '
            'directly.';
      }
    } else if (_localFiles['ota'] == null) {
      return 'Select a full TARGET OTA ZIP before flashing directly.';
    }
    return '';
  }

  bool get canFlashDirect =>
      directFlashRequirementsError.isEmpty &&
      !_bloatDownloading &&
      !catalogLoading;

  /// The OTA input a direct flash reads in place, or null when it cannot.
  Map<String, Object?>? get directFlashOta =>
      directFlashSupported ? otaInput('ota') : null;

  /// The verified bloat store a direct flash reads from.
  Map<String, Object?> get directFlashBloat => _bloatStore.toService();

  // ------------------------------------------------------- storage budget

  Map<String, Object?>? get budget => _budget;
  bool get budgetLoading => _budgetLoading;
  String? get budgetError => _budgetError;

  int get budgetCap => (_budget?['cap'] as num? ?? appStorageCapBytes).toInt();
  int get budgetUsage => (_budget?['usage'] as num? ?? 0).toInt();
  int get budgetQuota => (_budget?['quota'] as num? ?? 0).toInt();
  int get budgetAvailable => (_budget?['available'] as num? ?? 0).toInt();

  List<Map<String, Object?>> get cachedOtas {
    final items = _budget?['items'];
    if (items is! List) return const [];
    return [
      for (final item in items)
        if (item is Map) Map<String, Object?>.from(item),
    ];
  }

  bool get cachingOta => _cachingOta;
  String? get cacheOtaError => _cacheOtaError;
  Map<String, ({int done, int total})> get cacheProgress =>
      Map.unmodifiable(_cacheProgress);

  /// The cache key of a catalog entry, or null when the entry is not
  /// cacheable.
  String? cacheKeyFor(Map<String, dynamic> entry) {
    try {
      return otaEntryDigest(entry);
    } on Object {
      return null;
    }
  }

  bool isOtaCached(Map<String, dynamic> entry) {
    final key = cacheKeyFor(entry);
    if (key == null) return false;
    return cachedOtas.any(
      (item) => item['key'] == key && item['complete'] == true,
    );
  }

  /// Whether one more catalog OTA fits under the app cap and the platform
  /// quota. Unknown numbers never promise a fit.
  bool canKeepOtaOffline(Map<String, dynamic> entry) {
    if (!selectionValid || _cachingOta) return false;
    if (_budget == null || _budgetError != null) return false;
    final size = entry['size'];
    if (size is! num || size <= 0) return false;
    return size.toInt() <= budgetAvailable && !isOtaCached(entry);
  }

  Future<void> refreshBudget() async {
    if (_budgetLoading) return;
    _budgetLoading = true;
    _budgetError = null;
    _notify();
    try {
      final result = await runtime.service.storageBudget({
        'store': _bloatStore.toService(),
        'apiBase': runtime.apiBase,
      });
      if (_disposed) return;
      _budget = result;
    } on Object catch (error) {
      if (_disposed) return;
      _budget = null;
      _budgetError = '$error';
    } finally {
      if (!_disposed) {
        _budgetLoading = false;
        _notify();
      }
    }
  }

  /// Downloads the selected catalog OTA into the local OTA cache so it can be
  /// flashed offline. Only catalog sources are cacheable.
  Future<void> keepOtaOffline() async {
    final entry = _selectedReleases['ota'];
    if (entry == null || !canKeepOtaOffline(entry)) return;
    final ota = otaInput('ota');
    if (ota == null || ota['kind'] != 'catalog') return;
    final token = ++_cacheToken;
    _cachingOta = true;
    _cacheOtaError = null;
    _cachingKey = cacheKeyFor(entry);
    _cacheProgress.clear();
    _notify();
    _cacheSubscription = runtime.service
        .cacheOta({
          'store': _bloatStore.toService(),
          'apiBase': runtime.apiBase,
          'ota': ota,
        })
        .listen(
          (event) {
            if (_disposed || token != _cacheToken) return;
            switch (event['type']) {
              case 'progress':
                final label = event['label'];
                final done = event['done'];
                final total = event['total'];
                if (label is String && done is num && total is num) {
                  _cacheProgress[label] = (
                    done: done.toInt(),
                    total: total.toInt(),
                  );
                }
              case 'result':
                _cachingOta = false;
                _cachingKey = null;
                _cacheSubscription = null;
                unawaited(refreshBudget());
              default:
                break;
            }
            _notify();
          },
          onError: (Object error) {
            if (_disposed || token != _cacheToken) return;
            _cachingOta = false;
            _cachingKey = null;
            _cacheSubscription = null;
            _cacheOtaError = 'Could not keep the OTA offline: $error';
            _notify();
          },
          onDone: () {
            if (_disposed || token != _cacheToken) return;
            if (_cachingOta) {
              _cachingOta = false;
              _cachingKey = null;
              _cacheSubscription = null;
              _notify();
            }
          },
          cancelOnError: false,
        );
  }

  void cancelCacheOta() {
    if (!_cachingOta) return;
    _cacheToken++;
    _cachingOta = false;
    _cachingKey = null;
    unawaited(_cacheSubscription?.cancel());
    _cacheSubscription = null;
    _notify();
  }

  /// Removes one cached OTA from the store the budget covers.
  Future<void> evictCachedOta(String key) async {
    try {
      await runtime.service.evictCachedOta({
        'store': _bloatStore.toService(),
        'apiBase': runtime.apiBase,
        'key': key,
      });
      _budgetError = null;
    } on Object catch (error) {
      _budgetError = '$error';
      _notify();
    }
    await refreshBudget();
  }

  String? get cachingKey => _cachingKey;

  void _savePreferences() {
    final value = preferences
        .copyWith(
          device: _device,
          kind: _kind,
          region: _region,
          zipOutput: _zipOutput,
          vulnerableAbl: _vulnerableAbl,
        )
        .toJson();
    unawaited(
      runtime.bridge.writePreferences(value).catchError((Object _) {
        // Preferences are best effort, like upstream's settings write.
      }),
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _dropSubscription?.cancel();
    _launchSubscription?.cancel();
    _bloatSubscription?.cancel();
    _cacheSubscription?.cancel();
    if (_bloatAwake) {
      _bloatAwake = false;
      unawaited(runtime.bridge.endKeepAwake());
    }
    super.dispose();
  }
}

/// Wrappers around the core's catalog helpers keep this file's imports direct
/// and make the UI read like upstream's `ota_catalog` calls.
bool fileOtaCatalogNeedsMatchedOdm(String device, String kind, String region) =>
    needsMatchedOdm(device, kind, region);

Map<String, ({String device, String region})> otaCatalogTargets(
  String device,
  String kind,
  String region,
) => targets(device, kind, region);

List<Map<String, dynamic>> otaCatalogReleasesFor(
  Map<String, dynamic> data,
  String device,
  String region,
) => releasesFor(data, device, region);

Map<String, dynamic> otaCatalogMatchingOdm(
  Map<String, dynamic> data,
  Map<String, dynamic> target,
) => matchingOdm(data, target);
