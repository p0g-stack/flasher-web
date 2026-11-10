import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

import '../api/platform_bridge.dart';
import '../format.dart';
import '../preferences.dart';
import '../runtime.dart';
import 'export_controller.dart';
import 'ota_download_controller.dart';

/// Which OTA source step 3 shows.
enum OtaMode { localFile, catalog }

/// A store the service can open, chosen from facts plus a page-side pick.
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

/// The Flash or export form: selection, bloat, OTA, ABL and gating.
///
/// Gating texts are ports of upstream `build_requirements_error` and
/// `update_summary`.
final class SetupState extends ChangeNotifier {
  static final _log = Logger('ui.setup');

  SetupState({
    required this.runtime,
    required this.tables,
    required this.environment,
    required this.preferences,
  }) : exports = ExportController(
         api: runtime.service,
         bridge: runtime.bridge,
         upstreamBase: runtime.upstreamBase,
       ),
       otaDownloads = OtaDownloadController(
         api: runtime.service,
         bridge: runtime.bridge,
       ) {
    otaDownloads.addListener(_notify);
    _device = _initialDevice();
    _kind = _initialKind();
    _region = _initialRegion();
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

  /// Streams the same package to a save-picker file.
  final ExportController exports;

  /// Copies a catalog OTA onto this computer.
  final OtaDownloadController otaDownloads;

  late String _device;
  late String _kind;
  late String _region;
  bool? _vulnerableAbl;

  OtaMode _otaMode = OtaMode.localFile;

  StoreChoice _bloatStore = const StoreChoice.browser();
  String? _pendingBloatFolder;
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

  String get device => _device;
  String get kind => _kind;
  String get region => _region;
  bool? get vulnerableAbl => _vulnerableAbl;
  OtaMode get otaMode => _otaMode;
  StoreChoice get bloatStore => _bloatStore;
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
      ? 'CONFIGURE → BLOAT FILES → OTA → ABL → FLASH OR EXPORT'
      : 'CONFIGURE → BLOAT FILES → OTA → FLASH OR EXPORT';

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
    if (needsMatchedOdm) {
      return 'Only odm.img is streamed; the donor must have the same '
          'security patch.';
    }
    if (_otaMode == OtaMode.catalog) {
      return 'Choose a version to stream directly. Temporary links are '
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

  void setOtaMode(OtaMode mode) {
    if (_otaMode == mode) return;
    _otaMode = mode;
    _notify();
    if (mode == OtaMode.catalog && _catalogData == null && !_catalogLoading) {
      unawaited(fetchCatalog());
    }
  }

  void _afterSelectionChange() {
    _populateCatalog();
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
    'format': 'Direct flash or ZIP export',
    'engine': environment.native ? 'Rust / WebAssembly' : 'Dart worker',
    'version': selectedVersion ?? '—',
  };

  // ------------------------------------------------------------- bloat store

  bool get canChangeStores => !_bloatDownloading;

  /// The name of a remembered bloat folder whose permission must be renewed.
  String? get pendingBloatFolderName => _pendingBloatFolder;

  String? get storeError => _storeError;

  Future<void> chooseBloatFolder() async {
    try {
      final ref = await runtime.bridge.pickDirectory(
        'bloat',
        label: 'Choose bloat download folder',
      );
      if (ref == null) return;
      _pendingBloatFolder = null;
      _storeError = null;
      _setBloatStore(StoreChoice.folder(ref));
    } on Object catch (error) {
      _storeError = '$error';
      _notify();
    }
  }

  Future<void> reconnectBloatFolder() async {
    try {
      final ref = await runtime.bridge.requestRememberedDirectory('bloat');
      if (ref == null) return;
      _pendingBloatFolder = null;
      _setBloatStore(StoreChoice.folder(ref));
    } on Object catch (error) {
      _bloatError = '$error';
      _notify();
    }
  }

  void useBrowserStorage() {
    _pendingBloatFolder = null;
    _setBloatStore(const StoreChoice.browser());
  }

  void _setBloatStore(StoreChoice choice) {
    _bloatStore = choice;
    unawaited(refreshBloat());
    unawaited(refreshBudget());
    _notify();
  }

  Future<void> _restoreStores() async {
    if (!pickerAvailable) return;
    try {
      final ref = await runtime.bridge.rememberedDirectory('bloat');
      if (_disposed) return;
      if (ref != null) {
        _setBloatStore(StoreChoice.folder(ref));
        return;
      }
      final name = await runtime.bridge.rememberedDirectoryName('bloat');
      if (_disposed) return;
      if (name != null) _pendingBloatFolder = name;
    } on Object {
      // A missing or unreadable handle simply leaves the default store.
    }
    _notify();
  }

  // ----------------------------------------------------------- direct flash

  /// Every flasher kind the service can represent as a virtual package. Super
  /// kinds pack the same sparse super image the normal build writes.
  static const _directFlashKinds = {
    'Regional Flasher',
    'RegionalHybrid Flasher',
    'Super Flasher',
    'SuperHybrid Flasher',
  };

  /// Super kinds pack a super partition image; preparation decodes every
  /// logical image once instead of reusing staged files.
  bool get isSuperKind => _kind.contains('Super');

  bool get directFlashSupported =>
      selectionValid && _directFlashKinds.contains(_kind);

  /// Why the OTA-direct actions are not offered for this selection.
  String get directFlashUnavailable {
    if (!selectionValid) {
      return 'Choose a supported device, flasher type and region.';
    }
    if (directFlashSupported) return '';
    return '$_kind has no OTA-direct path. Flashing and exporting are offered '
        'for Regional, RegionalHybrid, Super and SuperHybrid flasher '
        'selections.';
  }

  /// The explanation under the enabled Continue button.
  String get directFlashHint {
    if (!isSuperKind) {
      return 'Continue to connect the phone and flash the OTA directly.';
    }
    return 'Continue to connect the phone and flash the OTA directly. Super '
        'preparation decodes the whole super image once (this can take '
        'several minutes) before the device is touched.';
  }

  /// Port of the direct-flash prerequisites: verified bloat, one TARGET OTA
  /// and the BASE OTA an Ace 6 conversion needs.
  String get directFlashRequirementsError => _requirementsError('continuing');

  /// The same inputs feed Export ZIP, so only the wording differs.
  String _requirementsError(String action) {
    if (!directFlashSupported) return directFlashUnavailable;
    if (isX9U && _vulnerableAbl == null) {
      return 'Step 4: choose Yes or No for vulnerable ABL before $action.';
    }
    if (!bloatReady) {
      return 'Required bloat files must be downloaded and verified before '
          '$action.';
    }
    for (final role in ['ota', if (needsBase) 'base']) {
      final title = role == 'ota' ? 'TARGET' : 'BASE';
      if (_otaMode == OtaMode.catalog) {
        if (_selectedReleases[role] == null) {
          return 'Select a full $title OTA catalog version before $action.';
        }
      } else if (_localFiles[role] == null) {
        return 'Select a full $title OTA ZIP before $action.';
      }
    }
    // The catalog ODM patch match is the only donor input: the service picks
    // the Ace 6T CN donor itself, and a local or downloaded target is matched
    // from its own security patch.
    if (_otaMode == OtaMode.catalog && needsMatchedOdm) {
      if (_selectedReleases['ota'] == null) {
        return 'Select a target OTA with a matching Ace 6T security patch.';
      }
      if (_odmError != null) return _odmError!;
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

  /// The BASE OTA input an Ace 6 conversion reads in place, or null.
  Map<String, Object?>? get directFlashBase =>
      directFlashSupported && needsBase ? otaInput('base') : null;

  /// The verified bloat store a direct flash reads from.
  Map<String, Object?> get directFlashBloat => _bloatStore.toService();

  // ------------------------------------------------------------------ export

  /// Whether this page can deliver an export at all.
  bool get canSaveZip => exports.available;

  /// Why Export ZIP is not offered, or empty when it is.
  String get exportRequirementsError {
    if (!canSaveZip) return exports.unavailableHint;
    return _requirementsError('exporting the package');
  }

  bool get canExportZip =>
      exportRequirementsError.isEmpty && !_bloatDownloading && !catalogLoading;

  /// Streams the package a direct flash would write into a save-picker file.
  Future<String?> exportZip() async {
    if (!canExportZip || selectionMap == null) {
      return 'The package inputs are not ready yet.';
    }
    final ota = otaInput('ota');
    if (ota == null) return 'Choose the TARGET OTA first.';
    final base = needsBase ? otaInput('base') : null;
    return exports.export(
      virtual: {
        'ota': ota,
        'base': ?base,
        'bloat': directFlashBloat,
        if (_vulnerableAbl != null) 'vulnerableAbl': _vulnerableAbl,
      },
      selection: Map<String, Object?>.from(selectionMap!),
      label: '$deviceDisplay $_kind $regionDisplay',
    );
  }

  // ------------------------------------------------------- storage budget

  bool get budgetLoading => _budgetLoading;
  String? get budgetError => _budgetError;

  int get budgetCap => (_budget?['cap'] as num? ?? appStorageCapBytes).toInt();
  int get budgetUsage => (_budget?['usage'] as num? ?? 0).toInt();
  int get budgetQuota => (_budget?['quota'] as num? ?? 0).toInt();
  int get budgetAvailable => (_budget?['available'] as num? ?? 0).toInt();

  /// Whether the catalog [role] may be downloaded now.
  bool canDownloadOta(String role) =>
      selectionValid &&
      !otaDownloads.running &&
      _otaMode == OtaMode.catalog &&
      _selectedReleases[role] != null;

  Future<void> refreshBudget() async {
    if (_budgetLoading) return;
    _budgetLoading = true;
    _budgetError = null;
    _notify();
    try {
      final result = await runtime.service.storageBudget({
        'store': _bloatStore.toService(),
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

  /// Saves the catalog [role] onto this computer and, where the browser can
  /// read the saved file back, makes it the local OTA for [role].
  ///
  /// Call from the click handler: the save picker needs the user gesture.
  Future<void> downloadOtaToComputer(String role) async {
    final entry = _selectedReleases[role];
    final ota = otaInput(role);
    if (entry == null || ota == null || !canDownloadOta(role)) return;
    await otaDownloads.toComputer(
      role: role,
      ota: ota,
      apiBase: runtime.apiBase,
      suggestedName: otaFileName(entry),
      onSaved: (file) => setLocalFile(role, file),
    );
  }

  /// The file name a saved catalog OTA gets: the CDN's own name when it is a
  /// ZIP, otherwise the version.
  static String otaFileName(Map<String, dynamic> entry) {
    final source = entry['source_url'];
    if (source is String) {
      final segments = Uri.tryParse(source)?.pathSegments ?? const <String>[];
      final last = segments.isEmpty ? '' : segments.last;
      if (last.toLowerCase().endsWith('.zip')) return last;
    }
    final version = entry['version'];
    final name = (version is String && version.isNotEmpty ? version : 'ota')
        .replaceAll(RegExp(r'[^A-Za-z0-9._()-]+'), '-');
    return '$name.zip';
  }

  void _savePreferences() {
    final value = preferences
        .copyWith(
          device: _device,
          kind: _kind,
          region: _region,
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
    otaDownloads
      ..removeListener(_notify)
      ..dispose();
    exports.dispose();
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
