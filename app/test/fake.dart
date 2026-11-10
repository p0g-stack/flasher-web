import 'dart:async';

import 'package:flasher_web/api/flasher_api.dart';
import 'package:flasher_web/api/platform_bridge.dart';
import 'package:flasher_web/preferences.dart';
import 'package:flasher_web/runtime.dart';
import 'package:flasher_web/shell.dart';
import 'package:flasher_web/theme.dart';
import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_usb_grant/web_usb_grant.dart';

/// The service methods, scripted per test.
final class FakeFlasherApi implements FlasherApi {
  Map<String, Object?> environmentResult = const {
    'facts': ['fs.opfs', 'net', 'usb.web'],
    'native': true,
    'upstream': 'abc123',
    'storage': {
      'opfs': true,
      'picker': false,
      'handle': false,
      'persisted': false,
      'quota': 64 * 1024 * 1024 * 1024,
      'usage': 2 * 1024 * 1024 * 1024,
    },
  };

  Map<String, Object?> bloatStatusResult = const {
    'total': 0,
    'downloaded': 0,
    'bytes': 0,
    'ready': true,
  };

  Map<String, Object?>? inspectResult;

  Map<String, dynamic> catalog = const {'api_version': '1', 'releases': []};

  List<Map<String, Object?>> fastbootDeviceItems = const [
    {'serial': 'SERIAL123', 'label': 'Realme NEO8', 'transport': 'usb'},
  ];

  /// Overrides the whole `{devices, error}` response when set.
  Map<String, Object?>? fastbootDevicesResponse;

  Stream<Map<String, Object?>> Function(Map<String, Object?> request)?
  bloatStream;
  Stream<Map<String, Object?>> Function(Map<String, Object?> request)?
  flashStream;
  Stream<Map<String, Object?>> Function(Map<String, Object?> request)? recoveryStream;
  Future<Map<String, Object?>> Function(Map<String, Object?> request)?
  stopResult;
  Map<String, Object?>? lastRecoveryRequest;
  String? lastRecoveryAction;
  Map<String, Object?>? lastStopRequest;

  Map<String, Object?> Function(Map<String, Object?> request)?
  prepareFlashResult;

  Map<String, Object?>? lastBloatRequest;
  Map<String, Object?>? lastPrepareRequest;
  Map<String, Object?>? lastFlashRequest;
  Map<String, Object?>? lastStorageBudgetRequest;
  Map<String, Object?>? lastSaveOtaRequest;
  Map<String, Object?>? lastExportRequest;
  Map<String, Object?>? lastInspectRequest;
  int prepareCalls = 0;
  int flashCalls = 0;

  Map<String, Object?> storageBudgetResult = const {
    'cap': 10 * 1024 * 1024 * 1024,
    'usage': 2 * 1024 * 1024 * 1024,
    'quota': 64 * 1024 * 1024 * 1024,
    'available': 8 * 1024 * 1024 * 1024,
  };

  Stream<Map<String, Object?>> Function(Map<String, Object?> request)?
  saveOtaStream;
  Stream<Map<String, Object?>> Function(Map<String, Object?> request)?
  exportVirtualStream;

  @override
  Future<Map<String, Object?>> environment() async => environmentResult;

  @override
  Future<Map<String, Object?>> bloatStatus(Map<String, Object?> request) async {
    lastBloatRequest = request;
    return bloatStatusResult;
  }

  @override
  Stream<Map<String, Object?>> downloadBloat(Map<String, Object?> request) {
    lastBloatRequest = request;
    return bloatStream?.call(request) ?? const Stream.empty();
  }

  @override
  Future<Map<String, Object?>> inspectOta(Map<String, Object?> request) async {
    lastInspectRequest = request;
    final result = inspectResult;
    if (result == null) throw StateError('No inspectOta result scripted.');
    return result;
  }

  @override
  Future<Map<String, Object?>> fastbootDevices() async =>
      fastbootDevicesResponse ?? {'devices': fastbootDeviceItems};

  @override
  Future<Map<String, Object?>> prepareFlash(
    Map<String, Object?> request,
  ) async {
    prepareCalls++;
    lastPrepareRequest = request;
    final handler = prepareFlashResult;
    if (handler == null) {
      throw StateError('No prepareFlash result scripted.');
    }
    return handler(request);
  }

  @override
  Stream<Map<String, Object?>> flash(Map<String, Object?> request) {
    flashCalls++;
    lastFlashRequest = request;
    return flashStream?.call(request) ?? const Stream.empty();
  }

  Stream<Map<String, Object?>> _recover(String action, Map<String, Object?> request) {
    lastRecoveryAction = action;
    lastRecoveryRequest = request;
    final handler = recoveryStream;
    if (handler == null) throw StateError('No recovery stream scripted.');
    return handler(request);
  }
  @override
  Stream<Map<String, Object?>> retryRead(Map<String, Object?> request) => _recover('retryRead', request);
  @override
  Stream<Map<String, Object?>> reconnectDevice(Map<String, Object?> request) => _recover('reconnectDevice', request);
  @override
  Stream<Map<String, Object?>> recoverBootloader(Map<String, Object?> request) => _recover('recoverBootloader', request);
  @override
  Stream<Map<String, Object?>> recoverFastbootd(Map<String, Object?> request) => _recover('recoverFastbootd', request);
  @override
  Stream<Map<String, Object?>> recoverPowerCycle(Map<String, Object?> request) => _recover('recoverPowerCycle', request);
  @override
  Stream<Map<String, Object?>> rewriteStep(Map<String, Object?> request) => _recover('rewriteStep', request);
  @override
  Stream<Map<String, Object?>> wipeSuper(Map<String, Object?> request) => _recover('wipeSuper', request);

  @override
  Future<Map<String, Object?>> stopRun(Map<String, Object?> request) async {
    lastStopRequest = request;
    final handler = stopResult;
    if (handler == null) throw StateError('No stop result scripted.');
    return handler(request);
  }

  @override
  Future<Map<String, Object?>> storageBudget(
    Map<String, Object?> request,
  ) async {
    lastStorageBudgetRequest = request;
    return storageBudgetResult;
  }

  @override
  Stream<Map<String, Object?>> saveOta(Map<String, Object?> request) {
    lastSaveOtaRequest = request;
    return saveOtaStream?.call(request) ?? const Stream.empty();
  }

  @override
  Stream<Map<String, Object?>> exportVirtual(Map<String, Object?> request) {
    lastExportRequest = request;
    return exportVirtualStream?.call(request) ?? const Stream.empty();
  }

  @override
  void dispose() {}
}

/// Page APIs without a browser: picker results and downloads are scripted.
final class FakePlatformBridge implements PlatformBridge {
  FakePlatformBridge({this.canPickDirectory = false, this.otaFile});

  @override
  final bool canPickDirectory;

  PickedFile? otaFile;

  @override
  bool canChooseFastbootDevice = true;

  /// Each call to the chooser consumes one entry; null means cancellation.
  final List<Object?> fastbootChoices = [];
  int chooseFastbootCalls = 0;

  final prefs = <String, Object?>{};
  final downloads = <String>[];
  final deleted = <String>[];
  final opened = <String>[];
  bool persistentGranted = true;
  int keepAwake = 0;
  Future<void>? keepAwakeGate;
  final _dropped = StreamController<PickedFile>.broadcast();
  final _usbEvents = StreamController<UsbAttachEvent>.broadcast();
  final _appUpdates = StreamController<String>.broadcast();

  @override
  bool wakeLockSupported = true;

  int reloads = 0;

  /// The checkpoint the page keeps across a reload.
  Map<String, Object?>? checkpoint;
  int checkpointWrites = 0;

  @override
  bool get available => true;

  @override
  Stream<UsbAttachEvent> get usbAttachEvents => _usbEvents.stream;

  void attach({required bool attached, String? serial, String? product}) =>
      _usbEvents.add(
        UsbAttachEvent(
          attached: attached,
          serial: serial,
          product: product,
        ),
      );

  @override
  Stream<String> get appUpdates => _appUpdates.stream;

  void announceUpdate(String version) => _appUpdates.add(version);

  @override
  void reloadPage() => reloads++;

  @override
  Future<Map<String, Object?>?> readFlashCheckpoint() async =>
      checkpoint == null ? null : Map<String, Object?>.from(checkpoint!);

  @override
  Future<void> writeFlashCheckpoint(Map<String, Object?> value) async {
    checkpointWrites++;
    checkpoint = Map<String, Object?>.from(value);
  }

  @override
  Future<void> clearFlashCheckpoint() async => checkpoint = null;

  @override
  Future<String> fetchText(String path) async => '';

  @override
  Future<Map<String, Object?>?> readPreferences() async =>
      prefs.isEmpty ? null : Map<String, Object?>.from(prefs);

  @override
  Future<void> writePreferences(Map<String, Object?> value) async {
    prefs
      ..clear()
      ..addAll(value);
  }

  @override
  Future<DirectoryRef?> pickDirectory(
    String key, {
    String label = 'Choose folder',
  }) async => null;

  @override
  Future<DirectoryRef?> rememberedDirectory(String key) async => null;

  @override
  Future<String?> rememberedDirectoryName(String key) async => null;

  @override
  Future<DirectoryRef?> requestRememberedDirectory(String key) async => null;

  @override
  Future<PickedFile?> pickOtaFile() async => otaFile;

  /// A remembered OTA the page may reopen after a reload.
  PickedFile? rememberedOta;
  bool otaPermissionGranted = true;

  /// The save-picker destination; null means the user cancelled.
  Object? saveFileResult = const _SaveDestination();

  @override
  bool canSaveFile = true;
  int pickSaveFileCalls = 0;
  final saveFileNames = <String>[];
  final savedFiles = <String>[];

  final _launched = StreamController<PickedFile>.broadcast();

  void launch(PickedFile file) => _launched.add(file);

  @override
  Stream<PickedFile> get launchedFiles => _launched.stream;

  @override
  Future<PickedFile?> rememberedOtaFile() async =>
      otaPermissionGranted ? rememberedOta : null;

  @override
  Future<String?> rememberedOtaFileName() async => rememberedOta?.name;

  @override
  Future<PickedFile?> requestRememberedOtaFile() async => rememberedOta;

  int forgetOtaCalls = 0;

  @override
  Future<void> forgetRememberedOta() async {
    forgetOtaCalls++;
    rememberedOta = null;
  }

  @override
  Future<Object?> pickSaveFile({required String suggestedName}) async {
    pickSaveFileCalls++;
    saveFileNames.add(suggestedName);
    return saveFileResult;
  }

  @override
  Future<void> saveStoreFile(
    String path, {
    Object? handle,
    required Object destination,
  }) async {
    savedFiles.add('$path|$destination');
  }

  /// The saved OTA [openSavedOta] returns, and the handles it was given.
  PickedFile? savedOta;
  final openedSavedOtas = <String>[];

  @override
  Future<PickedFile?> openSavedOta(
    Object destination, {
    required bool remember,
  }) async {
    openedSavedOtas.add('$destination|remember=$remember');
    if (remember) rememberedOta = savedOta;
    return savedOta;
  }

  @override
  Future<FastbootDeviceChoice?> chooseFastbootDevice() async {
    chooseFastbootCalls++;
    if (fastbootChoices.isEmpty) return null;
    final next = fastbootChoices.removeAt(0);
    if (next is UsbException) throw next;
    return next as FastbootDeviceChoice?;
  }

  @override
  Stream<PickedFile> get droppedFiles => _dropped.stream;

  void drop(PickedFile file) => _dropped.add(file);

  @override
  Future<bool> requestPersistentStorage() async => persistentGranted;

  @override
  Future<void> downloadStoreFile(
    String path, {
    required String filename,
    Object? handle,
  }) async {
    downloads.add(path);
  }

  @override
  Future<void> downloadText(String text, String filename) async {
    downloads.add(filename);
  }

  @override
  Future<void> openExternal(String url) async => opened.add(url);

  @override
  Future<void> beginKeepAwake() async {
    keepAwake++;
    await keepAwakeGate;
  }

  @override
  Future<void> endKeepAwake() async => keepAwake--;

  @override
  Future<void> deleteStorePath(String path, {Object? handle}) async {
    deleted.add(path);
  }

  @override
  void dispose() {
    _dropped.close();
    _launched.close();
    _usbEvents.close();
    _appUpdates.close();
  }
}

/// A stand-in `FileSystemFileHandle` for save-picker scripts.
final class _SaveDestination {
  const _SaveDestination();

  @override
  String toString() => 'save-destination';
}

/// A small portion of the real upstream tables: two device families, the Ace 6
/// conversion and X9U, with the combinations the tests exercise.
UpstreamTables testTables() => UpstreamTables(
  commit: 'abc123',
  devices: const {
    'Oneplus 13': '13',
    'Oneplus Ace 6': 'Ace6',
    'Oneplus Ace 6T': 'Ace6T',
    'OPPO Find X9 Ultra': 'X9U',
  },
  regionSizes: const {
    '13': RegionSizes(15354134528, 15354134528),
    'Ace6': RegionSizes(17272143872, 17272143872),
    'Ace6T': RegionSizes(16886267904, 16886267904),
    'X9U': RegionSizes(0, 0),
  },
  builders: const [
    BuilderEntry(
      type: 'SuperHybrid Flasher',
      dev: '13',
      region: 'GLO',
      builder: 'BUILD_SUPER.sh',
    ),
    BuilderEntry(
      type: 'SuperHybrid Flasher',
      dev: '13',
      region: 'EU',
      builder: 'BUILD_SUPER.sh',
    ),
    BuilderEntry(
      type: 'SuperHybrid Flasher',
      dev: '13',
      region: 'IN',
      builder: 'BUILD_SUPER.sh',
    ),
    BuilderEntry(
      type: 'SuperHybrid Flasher',
      dev: '13',
      region: 'CN',
      builder: 'BUILD_SUPER.sh',
    ),
    BuilderEntry(
      type: 'SuperHybrid Flasher',
      dev: 'Ace6',
      region: 'IN',
      builder: 'BUILD_ACE6_OOS.sh',
    ),
    BuilderEntry(
      type: 'Super Flasher',
      dev: 'Ace6T',
      region: 'GLO',
      builder: 'BUILD_SUPER.sh',
    ),
    BuilderEntry(
      type: 'Super Flasher',
      dev: 'Ace6T',
      region: 'IN',
      builder: 'BUILD_SUPER.sh',
    ),
    BuilderEntry(
      type: 'Super Flasher',
      dev: 'X9U',
      region: 'GLO',
      builder: 'BUILD_SUPER.sh',
    ),
    BuilderEntry(
      type: 'Super Flasher',
      dev: 'X9U',
      region: 'CN',
      builder: 'BUILD_SUPER.sh',
    ),
    BuilderEntry(
      type: 'Regional Flasher',
      dev: '13',
      region: 'GLO',
      builder: 'BUILD_REGIONAL.sh',
    ),
    BuilderEntry(
      type: 'Regional Flasher',
      dev: '13',
      region: 'EU',
      builder: 'BUILD_REGIONAL.sh',
    ),
    BuilderEntry(
      type: 'Regional Flasher',
      dev: '13',
      region: 'IN',
      builder: 'BUILD_REGIONAL.sh',
    ),
    BuilderEntry(
      type: 'Regional Flasher',
      dev: '13',
      region: 'CN',
      builder: 'BUILD_REGIONAL.sh',
    ),
    BuilderEntry(
      type: 'Regional Flasher',
      dev: 'Ace6T',
      region: 'GLO',
      builder: 'BUILD_REGIONAL.sh',
    ),
    BuilderEntry(
      type: 'RegionalHybrid Flasher',
      dev: '13',
      region: 'GLO',
      builder: 'BUILD_REGIONAL.sh',
    ),
  ],
);

EnvironmentInfo testEnvironment({
  List<String> facts = const ['fs.opfs', 'net', 'usb.web'],
}) => EnvironmentInfo(
  facts: facts,
  native: true,
  upstream: 'abc123',
  storage: const StorageInfo(
    opfs: true,
    picker: false,
    handle: false,
    persisted: false,
    quota: 64 * 1024 * 1024 * 1024,
    usage: 2 * 1024 * 1024 * 1024,
  ),
);

final class Harness {
  Harness({
    FakePlatformBridge? bridge,
    UpstreamTables? tables,
    EnvironmentInfo? environment,
  }) : bridge = bridge ?? FakePlatformBridge(),
       tables = tables ?? testTables(),
       environment = environment ?? testEnvironment();

  final FakeFlasherApi api = FakeFlasherApi();
  final FakePlatformBridge bridge;
  final UpstreamTables tables;
  final EnvironmentInfo environment;
  final preferences = const SetupPreferences();

  AppRuntime get runtime => AppRuntime(
    service: api,
    bridge: bridge,
    loadTables: () async => tables,
    loadCatalog: ({bool force = false}) async => api.catalog,
    loadReadme: () async => '# Flasher Builder\n\nA test README.',
    dispose: () async {},
  );
}

Future<Harness> pumpApp(WidgetTester tester, {Harness? harness}) async {
  final h = harness ?? Harness();
  await tester.binding.setSurfaceSize(const Size(1440, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: themeFor(Brightness.light),
      home: AppShell(
        runtime: h.runtime,
        tables: h.tables,
        environment: h.environment,
        preferences: h.preferences,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> chooseDevice(WidgetTester tester, String device) async {
  await tester.tap(find.byKey(const ValueKey('deviceDropdown')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(device).last);
  await tester.pumpAndSettle();
}

Future<void> chooseKind(WidgetTester tester, String kind) async {
  await tester.tap(find.byKey(const ValueKey('kindDropdown')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(kind).last);
  await tester.pumpAndSettle();
}

String gating(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('directFlashError'))).data!;

String tooltip(WidgetTester tester) => tester
    .widget<Tooltip>(
      find.ancestor(
        of: find.byKey(const ValueKey('flashDirectButton')),
        matching: find.byType(Tooltip),
      ),
    )
    .message!;
