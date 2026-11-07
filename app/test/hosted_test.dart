import 'dart:async';
import 'dart:convert';

import 'package:flasher_web/build/build_controller.dart';
import 'package:flasher_web/build/hosted_api.dart';
import 'package:flasher_web/setup/setup_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fake.dart';

const _jobId = 'abcdefghijklmnopqrstuvwxyz123456';
const _sha = 'a4d3c2b1a4d3c2b1a4d3c2b1a4d3c2b1'
    'a4d3c2b1a4d3c2b1a4d3c2b1a4d3c2b1';

Map<String, Object?> _request() => {
  'hosted': true,
  'selection': const {
    'device': 'Oneplus 13',
    'kind': 'SuperHybrid Flasher',
    'region': 'GLO',
  },
  'catalogId': 'op13-glo-13.0.0.1',
};

Map<String, Object?> _success({
  Object? artifactUrl,
  bool includeBytes = true,
}) => {
  'id': _jobId,
  'status': 'succeeded',
  'events': [
    {'type': 'log', 'text': 'Fetched the catalog OTA.'},
    {'type': 'step', 'index': 4, 'total': 5, 'title': 'Package ZIP'},
  ],
  'artifactName': 'SuperHybrid Flasher 13 GLO.zip',
  'artifactUrl': artifactUrl ?? '/api/hosted/jobs/$_jobId/artifact',
  'sha256': _sha,
  if (includeBytes) 'bytes': 16 * 1024,
  'manifest': {
    'artifact': 'SuperHybrid Flasher 13 GLO.zip',
    'device': 'Oneplus 13',
    'arb': {'major': 1, 'minor': 2, 'index': 3},
  },
  'cache': {
    'hit': true,
    'lastUsed': '2026-11-01T00:00:00Z',
    'retainedUntil': '2027-03-31T00:00:00Z',
  },
};

HostedApiClient _client(MockClient client) => HostedApiClient(
  client: client,
  base: Uri.parse('https://site.example'),
);

Future<void> _settleCatalog(SetupState setup) async {
  for (var i = 0; i < 100 && setup.catalogLoading; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  if (setup.catalogData == null) await setup.fetchCatalog();
}

void main() {
  group('setup hosted mode', () {
    test('Ace 6 hosted request contains only catalog ids and base conversion', () async {
      final harness = Harness();
      harness.api.catalog = {
        'api_version': '1',
        'releases': [
          {
            'id': 'target-1',
            'device': 'OP 15R',
            'region': 'IN',
            'version': 'CPH2649_11.A.30',
            'source_url': 'https://example.test/target.zip',
            'security_patch': '2025-10-01',
          },
          {
            'id': 'base-1',
            'device': 'OP ACE 6',
            'region': 'CN',
            'version': 'PJV110_11.A.20',
            'source_url': 'https://example.test/base.zip',
          },
        ],
      };
      final setup = SetupState(
        runtime: harness.runtime,
        tables: harness.tables,
        environment: harness.environment,
        preferences: harness.preferences,
      );
      addTearDown(setup.dispose);
      await setup.refreshBloat(force: true);

      expect(setup.hostedAvailable, isFalse);
      setup.setHostedBuild(true);
      expect(setup.hostedBuild, isFalse);

      setup.selectDevice('Oneplus Ace 6');
      setup.setOtaMode(OtaMode.catalog);
      await _settleCatalog(setup);
      setup.setHostedBuild(true);
      expect(setup.hostedAvailable, isTrue);
      expect(setup.hostedBuild, isTrue);
      expect(setup.buildRequirementsError, isEmpty);

      final request = setup.buildRequest()!;
      expect(request, {
        'hosted': true,
        'selection': {
          'device': 'Oneplus Ace 6',
          'kind': 'SuperHybrid Flasher',
          'region': 'IN',
        },
        'catalogId': 'target-1',
        'baseCatalogId': 'base-1',
      });
      expect(request.containsKey('ota'), isFalse);
      expect(request.containsKey('base'), isFalse);
      expect(request.containsKey('output'), isFalse);
      expect(request.containsKey('zip'), isFalse);
      expect(jsonEncode(request), isNot(contains('example.test')));

      setup.setOtaMode(OtaMode.localFile);
      expect(setup.hostedBuild, isFalse);
    });

    test('X9U hosted mode needs the ABL choice but not local bloat', () async {
      final harness = Harness();
      harness.api.catalog = {
        'api_version': '1',
        'releases': [
          {
            'id': 'x9u-1',
            'device': 'OPPO FIND X9 ULTRA',
            'region': 'GLO',
            'version': 'X9U_11.A.10',
            'source_url': 'https://example.test/x9u.zip',
          },
        ],
      };
      harness.api.bloatStatusResult = const {
        'total': 2,
        'downloaded': 0,
        'bytes': 1024,
        'ready': false,
      };
      final setup = SetupState(
        runtime: harness.runtime,
        tables: harness.tables,
        environment: harness.environment,
        preferences: harness.preferences,
      );
      addTearDown(setup.dispose);
      await setup.refreshBloat(force: true);
      setup.selectDevice('OPPO Find X9 Ultra');
      setup.setOtaMode(OtaMode.catalog);
      await _settleCatalog(setup);

      expect(
        setup.buildRequirementsError,
        'Step 4: choose Yes or No for vulnerable ABL before building.',
      );
      setup.setVulnerableAbl(false);
      setup.setHostedBuild(true);
      expect(setup.buildRequirementsError, isEmpty);
      expect(setup.buildRequest()?['vulnerableAbl'], isFalse);
      expect(setup.buildRequest()?.containsKey('bloat'), isFalse);
    });

    test('base conversion gating names the missing base catalog version', () async {
      final harness = Harness();
      harness.api.catalog = {
        'api_version': '1',
        'releases': [
          {
            'id': 'target-1',
            'device': 'OP 15R',
            'region': 'IN',
            'version': 'CPH2649_11.A.30',
            'source_url': 'https://example.test/target.zip',
          },
        ],
      };
      final setup = SetupState(
        runtime: harness.runtime,
        tables: harness.tables,
        environment: harness.environment,
        preferences: harness.preferences,
      );
      addTearDown(setup.dispose);
      await setup.refreshBloat(force: true);
      setup.selectDevice('Oneplus Ace 6');
      setup.setOtaMode(OtaMode.catalog);
      await _settleCatalog(setup);
      setup.setHostedBuild(true);

      expect(
        setup.buildRequirementsError,
        'Select a full BASE OTA catalog version for the hosted build.',
      );
      expect(setup.buildRequest(), isNull);
    });
  });

  group('hosted request safety', () {
    test('local files, URLs and upload fields are rejected', () {
      for (final extra in [
        {'ota': {'kind': 'file', 'file': Object()}},
        {'url': 'https://evil.test/ota.zip'},
        {'upload': 'secret'},
        {'file': Object()},
      ]) {
        expect(
          () => HostedJobRequest.fromBuildRequest({..._request(), ...extra}),
          throwsA(isA<HostedApiException>()),
        );
      }
    });

    test('selection fields are whitelisted and ids cannot be URLs', () {
      expect(
        () => HostedJobRequest.fromBuildRequest({
          ..._request(),
          'selection': {
            'device': 'Oneplus 13',
            'kind': 'SuperHybrid Flasher',
            'region': 'GLO',
            'url': 'https://evil.test',
          },
        }),
        throwsA(isA<HostedApiException>()),
      );
      expect(
        () => HostedJobRequest.fromBuildRequest({
          ..._request(),
          'catalogId': 'https://evil.test/ota.zip',
        }),
        throwsA(isA<HostedApiException>()),
      );
      final request = HostedJobRequest.fromBuildRequest({
        ..._request(),
        'vulnerableAbl': false,
      });
      expect(request.toJson(), {
        'selection': {
          'device': 'Oneplus 13',
          'kind': 'SuperHybrid Flasher',
          'region': 'GLO',
        },
        'catalogId': 'op13-glo-13.0.0.1',
        'vulnerableAbl': false,
      });
    });
  });

  group('hosted build controller', () {
    test('posts only the catalog request and exposes artifact, manifest and cache', () async {
      final calls = <http.Request>[];
      final client = MockClient((request) async {
        calls.add(request);
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({'id': _jobId, 'status': 'queued'}),
            202,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(_success()),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final api = FakeFlasherApi();
      final bridge = FakePlatformBridge();
      final controller = BuildController(
        api: api,
        bridge: bridge,
        hosted: _client(client),
        hostedWait: (_) async {},
      );
      addTearDown(controller.dispose);

      await controller.start(
        request: _request(),
        summary: const {'device': 'OnePlus 13'},
      );

      expect(controller.phase, BuildPhase.succeeded);
      expect(controller.hosted, isTrue);
      expect(controller.hasResult, isTrue);
      expect(api.lastBuildRequest, isNull);
      expect(calls.map((call) => call.method), ['POST', 'GET']);
      expect(calls.first.url.toString(), 'https://site.example/api/hosted/jobs');
      expect(jsonDecode(calls.first.body), _request()..remove('hosted'));
      expect(calls.first.headers['content-type'], startsWith('application/json'));
      expect(calls.first.followRedirects, isFalse);
      expect(calls.last.url.path, '/api/hosted/jobs/$_jobId');
      expect(calls.last.headers['cache-control'], 'no-store');

      final result = controller.result!;
      expect(result['hosted'], isTrue);
      expect(result['job'], _jobId);
      expect(result['artifact'], 'SuperHybrid Flasher 13 GLO.zip');
      expect(result['format'], 'zip');
      expect(result['sha256'], _sha);
      expect(result['bytes'], 16 * 1024);
      expect(result['artifactUrl'], '/api/hosted/jobs/$_jobId/artifact');
      expect(result['manifestUrl'], '/api/hosted/jobs/$_jobId/manifest');
      expect(result['manifest'], isA<Map>());
      expect(controller.log, contains('Fetched the catalog OTA.'));
      expect(controller.log, contains('STEP 4/5: Package ZIP'));
      expect(controller.log, contains('Hosted package complete.'));
      expect(
        controller.cacheText,
        'Reused an identical cached build · last used 2026-11-01 · '
        'retained until 2027-03-31',
      );

      expect(await controller.downloadArtifact(), isNull);
      expect(bridge.downloads, isEmpty);
      expect(
        bridge.opened,
        contains('/api/hosted/jobs/$_jobId/artifact'),
      );
      expect(await controller.openManifest(), isNull);
      expect(
        bridge.opened,
        contains('/api/hosted/jobs/$_jobId/manifest'),
      );
    });

    test('polls queued and running jobs until success', () async {
      var gets = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({'id': _jobId, 'status': 'queued'}),
            202,
          );
        }
        gets++;
        if (gets == 1) {
          return http.Response(
            jsonEncode({
              'id': _jobId,
              'status': 'running',
              'events': [
                {'type': 'step', 'index': 2, 'total': 5, 'title': 'Fetch OTA'},
              ],
            }),
            200,
          );
        }
        return http.Response(jsonEncode(_success()), 200);
      });
      final controller = BuildController(
        api: FakeFlasherApi(),
        bridge: FakePlatformBridge(),
        hosted: _client(client),
        hostedWait: (_) async {},
      );
      addTearDown(controller.dispose);

      await controller.start(request: _request(), summary: const {});

      expect(gets, 2);
      expect(controller.phase, BuildPhase.succeeded);
      expect(controller.hostedStatus, HostedJobStatus.succeeded);
      expect(controller.stepIndex, controller.totalSteps);
    });

    test('keeps the server error evidence when a job fails', () async {
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({'id': _jobId, 'status': 'queued'}),
            202,
          );
        }
        return http.Response(
          jsonEncode({
            'id': _jobId,
            'status': 'failed',
            'events': [
              {'type': 'log', 'text': 'Packing failed.'},
            ],
            'error': 'No space left on the build volume.',
          }),
          200,
        );
      });
      final controller = BuildController(
        api: FakeFlasherApi(),
        bridge: FakePlatformBridge(),
        hosted: _client(client),
        hostedWait: (_) async {},
      );
      addTearDown(controller.dispose);

      await controller.start(request: _request(), summary: const {});

      expect(controller.phase, BuildPhase.failed);
      expect(
        controller.error,
        'No space left on the build volume.',
      );
      expect(controller.log, contains('Packing failed.'));
      expect(controller.result, isNull);
    });

    test('a success without bytes fails instead of supplying a bad flash target', () async {
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({'id': _jobId, 'status': 'queued'}),
            202,
          );
        }
        return http.Response(jsonEncode(_success(includeBytes: false)), 200);
      });
      final controller = BuildController(
        api: FakeFlasherApi(),
        bridge: FakePlatformBridge(),
        hosted: _client(client),
        hostedWait: (_) async {},
      );
      addTearDown(controller.dispose);

      await controller.start(request: _request(), summary: const {});

      expect(controller.phase, BuildPhase.failed);
      expect(controller.error, contains('artifact length'));
      expect(controller.result, isNull);
    });

    test('a foreign artifact URL is rejected', () async {
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({'id': _jobId, 'status': 'queued'}),
            202,
          );
        }
        return http.Response(
          jsonEncode(
            _success(artifactUrl: 'https://evil.test/artifact.zip'),
          ),
          200,
        );
      });
      final controller = BuildController(
        api: FakeFlasherApi(),
        bridge: FakePlatformBridge(),
        hosted: _client(client),
        hostedWait: (_) async {},
      );
      addTearDown(controller.dispose);

      await controller.start(request: _request(), summary: const {});

      expect(controller.phase, BuildPhase.failed);
      expect(controller.error, contains('foreign artifact URL'));
      expect(controller.result, isNull);
    });

    test('HTTP errors keep the server message and status', () async {
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode({'error': 'Catalog release is not allowed.'}),
          400,
        ),
      );
      final controller = BuildController(
        api: FakeFlasherApi(),
        bridge: FakePlatformBridge(),
        hosted: _client(client),
        hostedWait: (_) async {},
      );
      addTearDown(controller.dispose);

      await controller.start(request: _request(), summary: const {});

      expect(controller.phase, BuildPhase.failed);
      expect(
        controller.error,
        'Hosted build failed (HTTP 400): Catalog release is not allowed.',
      );
      expect(controller.result, isNull);
    });

    test('invalid source input never reaches the network', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response('{}', 200);
      });
      final controller = BuildController(
        api: FakeFlasherApi(),
        bridge: FakePlatformBridge(),
        hosted: _client(client),
      );
      addTearDown(controller.dispose);

      await controller.start(
        request: {
          ..._request(),
          'ota': {'kind': 'file', 'handle': Object()},
        },
        summary: const {},
      );

      expect(calls, 0);
      expect(controller.phase, BuildPhase.failed);
      expect(controller.error, contains('"ota" is not allowed'));
    });

    test('cancelling stops polling and leaves the server job running', () async {
      final wait = Completer<void>();
      var gets = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({'id': _jobId, 'status': 'queued'}),
            202,
          );
        }
        gets++;
        return http.Response(
          jsonEncode({'id': _jobId, 'status': 'running', 'events': []}),
          200,
        );
      });
      final controller = BuildController(
        api: FakeFlasherApi(),
        bridge: FakePlatformBridge(),
        hosted: _client(client),
        hostedWait: (_) => wait.future,
      );
      addTearDown(controller.dispose);

      final running = controller.start(request: _request(), summary: const {});
      while (controller.hostedStatus != HostedJobStatus.queued) {
        await Future<void>.delayed(Duration.zero);
      }
      controller.cancel();
      wait.complete();
      await running;

      expect(controller.phase, BuildPhase.canceled);
      expect(controller.log.last, contains('continues on the server'));
      expect(gets, 0);
    });
  });

  group('hosted output page', () {
    testWidgets('flash becomes available when a hosted result arrives', (
      tester,
    ) async {
      var gets = 0;
      final hosted = _client(
        MockClient((request) async {
          if (request.method == 'POST') {
            return http.Response(
              jsonEncode({'id': _jobId, 'status': 'queued'}),
              202,
            );
          }
          gets++;
          return http.Response(jsonEncode(_success()), 200);
        }),
      );
      final harness = Harness(hosted: hosted);
      harness.api.catalog = {
        'api_version': '1',
        'releases': [
          {
            'id': 'op13-glo-13.0.0.1',
            'device': 'OP 13',
            'region': 'GLO',
            'version': 'CPH2647_11.A.30',
            'source_url': 'https://example.test/ota.zip',
          },
        ],
      };
      addTearDown(hosted.close);
      await pumpApp(tester, harness: harness);

      await tester.tap(find.text('Version catalog'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('hostedBuildSwitch')),
      );
      await tester.tap(find.byKey(const ValueKey('hostedBuildSwitch')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Switch>(
              find.byKey(const ValueKey('hostedBuildSwitch')),
            )
            .value,
        isTrue,
      );

      await tester.ensureVisible(find.byKey(const ValueKey('buildButton')));
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('buildButton')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('buildButton')));
      await tester.pump();
      expect(find.byKey(const ValueKey('buildResult')), findsNothing);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(gets, 1);
      expect(harness.api.lastBuildRequest, isNull);
      expect(find.byKey(const ValueKey('buildResult')), findsOneWidget);
      expect(
        find.text('Build a package before flashing it.'),
        findsNothing,
      );
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('flashBuild')),
      );
      expect(button.onPressed, isNotNull);
    });
  });
}
