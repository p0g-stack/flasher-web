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

/// The six service methods, scripted per test.
final class FakeFlasherApi implements FlasherApi {
  Map<String, Object?> environmentResult = const {
    'facts': ['fs.opfs', 'net'],
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

  List<Map<String, Object?>> historyItems = const [];

  Stream<Map<String, Object?>> Function(Map<String, Object?> request)?
  buildStream;
  Stream<Map<String, Object?>> Function(Map<String, Object?> request)?
  bloatStream;

  Map<String, Object?>? lastBloatRequest;
  Map<String, Object?>? lastBuildRequest;
  bool buildCanceled = false;

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
    final result = inspectResult;
    if (result == null) throw StateError('No inspectOta result scripted.');
    return result;
  }

  @override
  Stream<Map<String, Object?>> build(Map<String, Object?> request) {
    lastBuildRequest = request;
    return buildStream?.call(request) ?? const Stream.empty();
  }

  @override
  Future<List<Map<String, Object?>>> history(
    Map<String, Object?> request,
  ) async => historyItems;

  @override
  void dispose() {}
}

/// Page APIs without a browser: picker results and downloads are scripted.
final class FakePlatformBridge implements PlatformBridge {
  FakePlatformBridge({this.canPickDirectory = false, this.otaFile});

  @override
  final bool canPickDirectory;

  PickedFile? otaFile;

  final prefs = <String, Object?>{};
  final downloads = <String>[];
  final deleted = <String>[];
  final opened = <String>[];
  bool persistentGranted = true;
  int keepAwake = 0;
  final _dropped = StreamController<PickedFile>.broadcast();

  @override
  bool get available => true;

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
  Future<void> beginKeepAwake() async => keepAwake++;

  @override
  Future<void> endKeepAwake() async => keepAwake--;

  @override
  Future<void> deleteStorePath(String path, {Object? handle}) async {
    deleted.add(path);
  }

  @override
  void dispose() {
    _dropped.close();
  }
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
      builder: 'BUILD_SUPER.sh',
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
  ],
);

EnvironmentInfo testEnvironment() => const EnvironmentInfo(
  facts: ['fs.opfs', 'net'],
  native: true,
  upstream: 'abc123',
  storage: StorageInfo(
    opfs: true,
    picker: false,
    handle: false,
    persisted: false,
    quota: 64 * 1024 * 1024 * 1024,
    usage: 2 * 1024 * 1024 * 1024,
  ),
);

final class Harness {
  Harness({FakePlatformBridge? bridge, UpstreamTables? tables})
    : bridge = bridge ?? FakePlatformBridge(),
      tables = tables ?? testTables();

  final FakeFlasherApi api = FakeFlasherApi();
  final FakePlatformBridge bridge;
  final UpstreamTables tables;
  final environment = testEnvironment();
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
    tester.widget<Text>(find.byKey(const ValueKey('gatingError'))).data!;

String tooltip(WidgetTester tester) => tester
    .widget<Tooltip>(
      find.ancestor(
        of: find.byKey(const ValueKey('buildButton')),
        matching: find.byType(Tooltip),
      ),
    )
    .message!;
