import 'package:flasher_web_core/flasher_web_core.dart';

import 'api/bridge.dart';
import 'api/flasher_api.dart';
import 'api/platform_bridge.dart';
import 'service/squadron_api.dart';

/// Browser storage capacity and support reported by the service.
final class StorageInfo {
  const StorageInfo({
    required this.opfs,
    required this.picker,
    required this.handle,
    required this.persisted,
    required this.quota,
    required this.usage,
  });

  factory StorageInfo.fromJson(Object? value) {
    final map = value is Map ? value : const {};
    int number(Object? value) => value is num && value >= 0 ? value.toInt() : 0;
    return StorageInfo(
      opfs: map['opfs'] == true,
      picker: map['picker'] == true,
      handle: map['handle'] == true,
      persisted: map['persisted'] == true,
      quota: number(map['quota']),
      usage: number(map['usage']),
    );
  }

  final bool opfs;
  final bool picker;
  final bool handle;
  final bool persisted;
  final int quota;
  final int usage;

  double get fraction => quota > 0 ? (usage / quota).clamp(0.0, 1.0) : 0;
}

/// The environment facts of the place the service runs in.
final class EnvironmentInfo {
  const EnvironmentInfo({
    required this.facts,
    required this.native,
    required this.upstream,
    required this.storage,
  });

  factory EnvironmentInfo.fromJson(Map<String, Object?> json) {
    final facts = json['facts'];
    return EnvironmentInfo(
      facts: facts is List
          ? [
              for (final fact in facts)
                if (fact is String) fact,
            ]
          : const [],
      native: json['native'] == true,
      upstream: json['upstream'] is String ? json['upstream']! as String : '',
      storage: StorageInfo.fromJson(json['storage']),
    );
  }

  final List<String> facts;
  final bool native;
  final String upstream;
  final StorageInfo storage;

  bool has(String fact) => facts.contains(fact);

  static const empty = EnvironmentInfo(
    facts: [],
    native: false,
    upstream: '',
    storage: StorageInfo(
      opfs: false,
      picker: false,
      handle: false,
      persisted: false,
      quota: 0,
      usage: 0,
    ),
  );
}

/// Everything a page needs to talk to the service and the browser.
final class AppRuntime {
  AppRuntime({
    required this.service,
    required this.bridge,
    required this.loadTables,
    required this.loadCatalog,
    required this.loadReadme,
    required this.dispose,
    this.apiBase = '',
    this.upstreamBase = 'upstream/',
  });

  final FlasherApi service;
  final PlatformBridge bridge;

  /// `upstream/tables.json` from the page origin.
  final Future<UpstreamTables> Function() loadTables;

  /// `/api/catalog`, with the 15-minute cache handled by [CatalogClient].
  final Future<Map<String, dynamic>> Function({bool force}) loadCatalog;

  /// `upstream/README.md` from the page origin.
  final Future<String> Function() loadReadme;

  /// Releases the worker, HTTP client and page listeners.
  final Future<void> Function() dispose;

  /// Origin serving `/api/*`.
  final String apiBase;

  /// Where `tables.json`, templates and the bloat manifest are served.
  final String upstreamBase;
}

/// Wires the real worker, HTTP catalog and browser bridge.
AppRuntime createRuntime() {
  final bridge = createPlatformBridge();
  final worker = localPlace.bind<FlasherServiceWorker>(
    withLogs(FlasherServiceWorker()),
    service: 'flasher',
  );
  final transport = HttpCatalogTransport();
  final catalog = CatalogClient(transport: transport);
  final base = Uri.base;
  return AppRuntime(
    service: SquadronFlasherApi(worker),
    bridge: bridge,
    loadTables: () async =>
        UpstreamTables.parse(await bridge.fetchText('upstream/tables.json')),
    loadCatalog: ({bool force = false}) => catalog.loadCatalog(force: force),
    loadReadme: () => bridge.fetchText('upstream/README.md'),
    apiBase: base.origin,
    upstreamBase: base.resolve('upstream/').toString(),
    dispose: () async {
      worker.terminate();
      bridge.dispose();
      transport.close();
    },
  );
}
