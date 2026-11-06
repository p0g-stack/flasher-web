import 'dart:convert';
import 'dart:typed_data';

import 'package:flasher_web_core/src/catalog/catalog_client.dart';
import 'package:flasher_web_core/src/catalog/ota_catalog.dart';
import 'package:test/test.dart';

typedef Handler = Future<CatalogResponse> Function(
  String method,
  Uri uri,
  Map<String, String> headers,
  String body,
);

final class FakeTransport implements CatalogTransport {
  FakeTransport(this.handler);

  final Handler handler;
  final List<
    ({String method, Uri uri, Map<String, String> headers, String body})
  >
  calls = [];

  @override
  Future<CatalogResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) {
    calls.add((method: 'GET', uri: uri, headers: headers, body: ''));
    return handler('GET', uri, headers, '');
  }

  @override
  Future<CatalogResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    required String body,
  }) {
    calls.add((method: 'POST', uri: uri, headers: headers, body: body));
    return handler('POST', uri, headers, body);
  }
}

CatalogResponse jsonResponse(
  Object? body, {
  int status = 200,
  Map<String, String> headers = const {},
}) => CatalogResponse(
  statusCode: status,
  body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
  headers: headers,
);

CatalogResponse rawResponse(
  String body, {
  int status = 200,
  Map<String, String> headers = const {},
}) => CatalogResponse(
  statusCode: status,
  body: Uint8List.fromList(utf8.encode(body)),
  headers: headers,
);

CatalogResponse notModified({Map<String, String> headers = const {}}) =>
    CatalogResponse(statusCode: 304, body: Uint8List(0), headers: headers);

Map<String, dynamic> release({
  String id = 'stable-id',
  String device = 'OP 13',
  String region = 'GLO',
  String version = 'CPH2653_16.0.10.600(EX01)',
  String source = 'https://ota.example/downloadCheck?token=test',
  bool isLatest = true,
  String? model = 'CPH2653',
  String? otaVersion,
  String? patch,
  String? timestamp,
}) {
  final entry = <String, dynamic>{
    'id': id,
    'device': device,
    'region': region,
    'version': version,
    'source_url': source,
    'is_latest': isLatest,
  };
  if (model != null) entry['model'] = model;
  if (otaVersion != null) entry['ota_version'] = otaVersion;
  if (patch != null) entry['security_patch'] = patch;
  if (timestamp != null) entry['build_timestamp'] = timestamp;
  return entry;
}

Map<String, dynamic> catalog(List<Map<String, dynamic>> releases) => {
  'api_version': '1',
  'releases': releases,
};

void main() {
  group('targets', () {
    test('Ace 6 SuperHybrid IN needs an OP 15R target and a CN base', () {
      expect(targets('Oneplus Ace 6', 'SuperHybrid Flasher', 'IN'), {
        'ota': (device: 'OP 15R', region: 'IN'),
        'base': (device: 'OP ACE 6', region: 'CN'),
      });
    });

    test('Ace 6T IN/GLO uses an OP 15R ODM donor', () {
      for (final region in ['IN', 'GLO']) {
        expect(
          needsMatchedOdm('Oneplus Ace 6T', 'Super Flasher', region),
          isTrue,
        );
        expect(targets('Oneplus Ace 6T', 'Super Flasher', region), {
          'ota': (device: 'OP 15R', region: region),
        });
      }
      expect(needsMatchedOdm('Oneplus Ace 6T', 'Super Flasher', 'CN'), isFalse);
      expect(
        needsMatchedOdm('Oneplus Ace 6T', 'SuperHybrid Flasher', 'IN'),
        isFalse,
      );
      expect(targets('Oneplus Ace 6T', 'Super Flasher', 'CN'), {
        'ota': (device: 'OP ACE 6T', region: 'CN'),
      });
    });

    test('every workflow device has a catalog mapping', () {
      expect(DEVICE_NAMES, hasLength(17));
      expect(targets('Oneplus Pad 2 Pro', 'SuperHybrid Flasher', 'CN')['ota'], (
        device: 'OP PAD2 PRO',
        region: 'CN',
      ));
      expect(
        () => targets('Unknown', 'Super Flasher', 'CN'),
        throwsA(
          isA<CatalogException>().having(
            (error) => error.message,
            'message',
            'This device has no OTA catalog mapping.',
          ),
        ),
      );
    });

    test('only OP 13 and OP 15 read the dedicated NA feed', () {
      expect(usesNaApi('Oneplus 13', 'NA'), isTrue);
      expect(usesNaApi('Oneplus 15', 'NA'), isTrue);
      expect(usesNaApi('OP 13', 'NA'), isTrue);
      expect(usesNaApi('Oneplus 15', 'EU'), isFalse);
      expect(usesNaApi('Oneplus 13R', 'NA'), isFalse);
    });
  });

  group('security patch', () {
    test('requires and validates a complete ISO date', () {
      expect(patchDate('2026-02-28'), '2026-02-28');
      expect(
        () => patchDate(null),
        throwsA(
          isA<CatalogException>().having(
            (error) => error.message,
            'message',
            'A complete security patch date is required to match the ODM '
                'source.',
          ),
        ),
      );
      expect(() => patchDate('2026-2-28'), throwsA(isA<CatalogException>()));
      expect(
        () => patchDate('2026-02-30'),
        throwsA(
          isA<CatalogException>().having(
            (error) => error.message,
            'message',
            'The security patch date is invalid.',
          ),
        ),
      );
    });

    test('matching ODM takes the exact patch and rejects a substitution', () {
      final data = catalog([
        release(
          id: 'old',
          device: 'OP ACE 6T',
          region: 'CN',
          patch: '2026-01-01',
          version: 'CPH2749_16.0.1.100',
        ),
        release(
          id: 'wanted',
          device: 'OP ACE 6T',
          region: 'CN',
          patch: '2026-02-01',
          version: 'CPH2749_16.0.2.100',
        ),
      ]);
      expect(
        matchingOdm(data, {'security_patch': '2026-02-01'})['id'],
        'wanted',
      );
      expect(
        () => matchingOdm(data, {'security_patch': '2026-03-01'}),
        throwsA(
          isA<CatalogException>().having(
            (error) => error.message,
            'message',
            'No Ace 6T CN OTA has security patch 2026-03-01. Choose a target '
                'with an exact patch match; a different ODM will not be '
                'substituted.',
          ),
        ),
      );
      expect(
        () => matchingOdm(data, {'security_patch': '2026-02-30'}),
        throwsA(isA<CatalogException>()),
      );
    });
  });

  group('releaseFromMetadata', () {
    test('matches an exact ota_version before considering a build number', () {
      final data = catalog([
        release(
          id: 'exact',
          device: 'OP 15R',
          region: 'IN',
          version: 'CPH2749_16.0.5.600(EX01)',
          otaVersion: 'CPH2749_16.0.5.600(EX01)',
        ),
        release(
          id: 'newer',
          device: 'OP 15R',
          region: 'IN',
          version: 'CPH2749_16.0.6.700(EX01)',
          model: 'CPH2749',
        ),
      ]);
      expect(
        releaseFromMetadata(data, 'OP 15R', 'IN', {
          'version_name': 'CPH2749_16.0.5.600(EX01)',
        })['id'],
        'exact',
      );
    });

    test('matches model and a complete version from metadata', () {
      final data = catalog([
        release(
          id: 'right',
          device: 'OP 15R',
          region: 'IN',
          version: 'CPH2749_16.0.5.600(EX01)',
          model: 'CPH2749',
        ),
        release(
          id: 'other',
          device: 'OP 15R',
          region: 'IN',
          version: 'CPH2749_16.0.4.500(EX01)',
          model: 'CPH2749',
        ),
      ]);
      expect(
        releaseFromMetadata(data, 'OP 15R', 'IN', {
          'version_name': 'CPH2749_16.0.5.600(EX01)',
        })['id'],
        'right',
      );
    });

    test('ambiguity and no match raise upstream messages', () {
      final ambiguous = catalog([
        release(
          id: 'one',
          device: 'OP 15R',
          region: 'IN',
          otaVersion: 'same',
          model: 'CPH2749',
        ),
        release(
          id: 'two',
          device: 'OP 15R',
          region: 'IN',
          otaVersion: 'same',
          model: 'CPH2749',
        ),
      ]);
      final message =
          'Could not identify this local OTA as an exact OnePlus 15R version '
          'for the selected region. Select its version in the catalog or use '
          'a matching full OTA.';
      expect(
        () => releaseFromMetadata(ambiguous, 'OP 15R', 'IN', {
          'ota_version': 'same',
        }),
        throwsA(
          isA<CatalogException>().having(
            (error) => error.message,
            'message',
            message,
          ),
        ),
      );
      expect(
        () => releaseFromMetadata(catalog([]), 'OP 15R', 'IN', {
          'version_name': 'nothing',
        }),
        throwsA(isA<CatalogException>()),
      );
    });
  });

  group('releasesFor', () {
    test('sorts versions naturally, exact device and region only', () {
      final data = catalog([
        release(id: '9', version: '9', isLatest: false),
        release(id: '10', version: '10', isLatest: false),
        release(id: 'cn', region: 'CN'),
        release(id: 'other-device', device: 'OP 15'),
      ]);
      expect(releasesFor(data, 'OP 13', 'GLO').map((entry) => entry['id']), [
        '10',
        '9',
      ]);
      expect(releasesFor(data, 'OP 13', 'NA'), isEmpty);
    });

    test('is_latest, build timestamp, version and stable ties', () {
      final data = catalog([
        release(id: 'vold', version: '16.0.9', isLatest: false),
        release(id: 'latest', version: '16.0.8', isLatest: true),
        release(
          id: 'newer-build',
          version: '16.0.10',
          isLatest: false,
          timestamp: '2026-02-01',
        ),
        release(
          id: 'older-build',
          version: '16.0.10',
          isLatest: false,
          timestamp: '2026-01-01',
        ),
        release(id: 'tie-a', version: '16.0.7', isLatest: false),
        release(id: 'tie-b', version: '16.0.7', isLatest: false),
      ]);
      expect(releasesFor(data, 'OP 13', 'GLO').map((entry) => entry['id']), [
        'latest',
        'newer-build',
        'older-build',
        'vold',
        'tie-a',
        'tie-b',
      ]);
    });

    test('a missing release id raises the refresh message', () {
      expect(
        () => findReleaseIn(catalog([release()]), 'gone', 'OP 13', 'GLO'),
        throwsA(
          isA<CatalogException>().having(
            (error) => error.message,
            'message',
            'The selected OTA version is no longer listed for this device/'
                'region. Fetch versions again.',
          ),
        ),
      );
    });
  });

  group('validateCatalog', () {
    test('accepts version 1 envelopes and returns the same object', () {
      final data = <String, dynamic>{
        'api_version': 1,
        'releases': [release(source: 'HTTPS://ota.example/file.zip')],
      };
      expect(validateCatalog(data), same(data));
    });

    test('rejects unsupported envelopes, incomplete and invalid releases', () {
      for (final data in <Object?>[
        null,
        <String, dynamic>{},
        {'api_version': '2', 'releases': <Object?>[]},
        {'api_version': '1', 'releases': 'no'},
      ]) {
        expect(
          () => validateCatalog(data),
          throwsA(
            isA<CatalogException>().having(
              (error) => error.message,
              'message',
              'The OTA service returned an unsupported catalog format.',
            ),
          ),
        );
      }
      expect(
        () => validateCatalog({
          'api_version': '1',
          'releases': [
            {'id': 'x', 'device': 'OP 13', 'region': 'GLO'},
          ],
        }),
        throwsA(
          isA<CatalogException>().having(
            (error) => error.message,
            'message',
            'The OTA catalog contains an incomplete release.',
          ),
        ),
      );
      expect(
        () => validateCatalog(catalog([release(), release()])),
        throwsA(
          isA<CatalogException>().having(
            (error) => error.message,
            'message',
            'The OTA catalog contains an invalid release.',
          ),
        ),
      );
      expect(
        () => validateCatalog(catalog([release(source: 'ftp://example/file')])),
        throwsA(isA<CatalogException>()),
      );
    });
  });

  group('CatalogClient feeds', () {
    test(
      'reads /api/catalog?na=0, caches 15 minutes and revalidates ETag',
      () async {
        final calls = <Uri>[];
        var now = DateTime.utc(2026, 1, 1);
        final data = catalog([release()]);
        final transport = FakeTransport((method, uri, headers, body) async {
          calls.add(uri);
          if (headers.containsKey('If-None-Match')) return notModified();
          return jsonResponse(data, headers: {'ETag': 'abc'});
        });
        final client = CatalogClient(
          transport: transport,
          base: Uri.parse('https://edge.example/'),
          clock: () => now,
        );

        expect(await client.loadCatalog(), data);
        expect(calls, [Uri.parse('https://edge.example/api/catalog?na=0')]);
        expect(transport.calls.first.headers, isEmpty);

        now = now.add(const Duration(minutes: 14, seconds: 59));
        expect(await client.loadCatalog(), data);
        expect(calls, hasLength(1));

        now = now.add(const Duration(seconds: 1));
        expect(await client.loadCatalog(), data);
        expect(calls, hasLength(2));
        expect(transport.calls.last.headers, {'If-None-Match': 'abc'});

        now = now.add(const Duration(minutes: 1));
        expect(await client.loadCatalog(force: true), data);
        expect(transport.calls.last.headers, {'If-None-Match': 'abc'});
      },
    );

    test('304 refreshes the fresh window without changing data', () async {
      var now = DateTime.utc(2026, 1, 1);
      final data = catalog([release()]);
      var revalidated = false;
      final transport = FakeTransport((method, uri, headers, body) async {
        if (headers.containsKey('If-None-Match')) {
          revalidated = true;
          return notModified(headers: {'ETag': 'abc'});
        }
        return jsonResponse(data, headers: {'ETag': 'abc'});
      });
      final client = CatalogClient(transport: transport, clock: () => now);
      await client.loadCatalog();
      expect(await client.loadCatalog(force: true), data);
      expect(revalidated, isTrue);
      final requests = transport.calls.length;
      now = now.add(const Duration(minutes: 10));
      await client.loadCatalog();
      expect(transport.calls.length, requests);
    });

    test('a 304 with no cached copy is an empty catalog', () async {
      final transport = FakeTransport(
        (method, uri, headers, body) async => notModified(),
      );
      final client = CatalogClient(transport: transport);
      expect(
        () => client.loadCatalog(force: true),
        throwsA(
          isA<CatalogException>().having(
            (error) => error.message,
            'message',
            'The OTA service returned an empty catalog.',
          ),
        ),
      );
    });

    test(
      'HTTP, transport and oversized failures use upstream messages',
      () async {
        final data = catalog([release()]);
        final http = CatalogClient(
          transport: FakeTransport(
            (method, uri, headers, body) async =>
                jsonResponse(data, status: 503),
          ),
        );
        expect(
          () => http.loadCatalog(),
          throwsA(
            isA<CatalogException>().having(
              (error) => error.message,
              'message',
              'OTA service returned HTTP 503. Try again later.',
            ),
          ),
        );

        final offline = CatalogClient(
          transport: FakeTransport(
            (method, uri, headers, body) async => throw Exception('offline'),
          ),
        );
        expect(
          () => offline.loadCatalog(),
          throwsA(
            isA<CatalogException>().having(
              (error) => error.message,
              'message',
              'Could not reach the OTA service. Check your connection and try '
                  'again.',
            ),
          ),
        );

        final oversized = CatalogClient(
          transport: FakeTransport(
            (method, uri, headers, body) async => jsonResponse(data),
          ),
          maxResponseBytes: 10,
        );
        expect(
          () => oversized.loadCatalog(),
          throwsA(
            isA<CatalogException>().having(
              (error) => error.message,
              'message',
              'The OTA service returned an oversized response.',
            ),
          ),
        );
      },
    );

    test('invalid JSON on a fresh feed is an invalid JSON error', () async {
      final client = CatalogClient(
        transport: FakeTransport(
          (method, uri, headers, body) async => rawResponse('{'),
        ),
      );
      expect(
        () => client.loadCatalog(),
        throwsA(
          isA<CatalogException>().having(
            (error) => error.message,
            'message',
            'The OTA service returned invalid JSON.',
          ),
        ),
      );
    });

    test('a cached feed is served stale when the next fetch fails', () async {
      var now = DateTime.utc(2026, 1, 1);
      var online = true;
      final data = catalog([release()]);
      final transport = FakeTransport((method, uri, headers, body) async {
        if (!online) throw Exception('offline');
        return jsonResponse(data, headers: {'ETag': 'abc'});
      });
      final client = CatalogClient(transport: transport, clock: () => now);
      await client.loadCatalog();
      online = false;
      now = now.add(const Duration(minutes: 16));
      final stale = await client.loadCatalog();
      expect(stale['releases'], data['releases']);
      expect(stale['_stale'], isTrue);
    });
  });

  group('CatalogClient NA merge', () {
    test('merges rebuilt NA with regular OP 15 NA only', () async {
      final rebuilt = [
        release(id: 'OP 13', device: 'OP 13', region: 'NA'),
        release(id: 'OP 15', device: 'OP 15', region: 'NA'),
        release(id: 'na-eu', device: 'OP 15', region: 'EU'),
      ];
      final regular = catalog([
        release(id: 'official15', device: 'OP 15', region: 'NA'),
        release(id: 'excluded13', device: 'OP 13', region: 'NA'),
        release(id: 'excluded-eu', device: 'OP 15', region: 'EU'),
        release(id: 'OP 15', device: 'OP 15', region: 'NA'),
      ]);
      final naData = <String, dynamic>{
        'api_version': '1',
        'count': 2,
        'releases': rebuilt,
      };
      final transport = FakeTransport((method, uri, headers, body) async {
        return jsonResponse(
          uri.queryParameters['na'] == '1' ? naData : regular,
        );
      });
      final client = CatalogClient(
        transport: transport,
        base: Uri.parse('https://edge.example/'),
      );
      final data = await client.loadCatalog(na: true);
      expect(
        {for (final entry in releasesFor(data, 'OP 15', 'NA')) entry['id']},
        {'OP 15', 'official15'},
      );
      expect(releasesFor(data, 'OP 13', 'NA').map((entry) => entry['id']), [
        'OP 13',
      ]);
      expect(releasesFor(data, 'OP 15', 'EU'), isEmpty);
      expect(data['count'], 3);
      expect(data.containsKey('_feed_errors'), isFalse);
      expect(transport.calls.map((call) => call.uri.query).toSet(), {
        'na=1',
        'na=0',
      });
    });

    test('either feed may fail without hiding the other', () async {
      final naData = catalog([
        release(id: 'rebuilt', device: 'OP 15', region: 'NA'),
        release(id: 'only-if-rebuilt', device: 'OP 13', region: 'NA'),
      ]);
      final regular = catalog([
        release(id: 'official', device: 'OP 15', region: 'NA'),
        release(id: 'only-if-regular', device: 'OP 13', region: 'NA'),
      ]);

      FakeTransport failing(String failed) =>
          FakeTransport((method, uri, headers, body) async {
            final dedicated = uri.queryParameters['na'] == '1';
            if (failed == (dedicated ? 'na' : 'regular')) {
              return jsonResponse({'error': 'down'}, status: 500);
            }
            return jsonResponse(dedicated ? naData : regular);
          });

      final naFailed = CatalogClient(transport: failing('na'));
      final onlyRegular = await naFailed.loadCatalog(na: true);
      expect(
        releasesFor(onlyRegular, 'OP 15', 'NA').map((entry) => entry['id']),
        ['official'],
      );
      expect(releasesFor(onlyRegular, 'OP 13', 'NA'), isEmpty);
      expect(onlyRegular['_feed_errors'], {
        'na': 'OTA service returned HTTP 500. Try again later.',
      });

      final regularFailed = CatalogClient(transport: failing('regular'));
      final onlyNa = await regularFailed.loadCatalog(na: true);
      expect(releasesFor(onlyNa, 'OP 15', 'NA').map((entry) => entry['id']), [
        'rebuilt',
      ]);
      expect(releasesFor(onlyNa, 'OP 13', 'NA').map((entry) => entry['id']), [
        'only-if-rebuilt',
      ]);
      expect(onlyNa['_feed_errors'], {
        'regular': 'OTA service returned HTTP 500. Try again later.',
      });
    });

    test('both feeds failing raises the NA feed error', () async {
      final client = CatalogClient(
        transport: FakeTransport(
          (method, uri, headers, body) async =>
              jsonResponse({'error': 'down'}, status: 500),
        ),
      );
      expect(
        () => client.loadCatalog(na: true),
        throwsA(
          isA<CatalogException>().having(
            (error) => error.message,
            'message',
            'OTA service returned HTTP 500. Try again later.',
          ),
        ),
      );
    });

    test('an invalid NA feed is reported while regular stays usable', () async {
      final client = CatalogClient(
        transport: FakeTransport((method, uri, headers, body) async {
          if (uri.queryParameters['na'] == '1') return rawResponse('{');
          return jsonResponse(
            catalog([release(id: 'official', device: 'OP 15', region: 'NA')]),
          );
        }),
      );
      final data = await client.loadCatalog(na: true);
      expect(data['_feed_errors'], {
        'na': 'The OTA service returned invalid JSON.',
      });
      expect(releasesFor(data, 'OP 15', 'NA').map((entry) => entry['id']), [
        'official',
      ]);
    });

    test('a stale NA feed stays stale after a failed revalidation', () async {
      var now = DateTime.utc(2026, 1, 1);
      var online = true;
      final naData = catalog([
        release(id: 'rebuilt', device: 'OP 15', region: 'NA'),
      ]);
      final regular = catalog([
        release(id: 'official', device: 'OP 15', region: 'NA'),
      ]);
      final client = CatalogClient(
        transport: FakeTransport((method, uri, headers, body) async {
          if (!online) throw Exception('offline');
          return jsonResponse(
            uri.queryParameters['na'] == '1' ? naData : regular,
            headers: {'ETag': 'abc'},
          );
        }),
        clock: () => now,
      );
      await client.loadCatalog(na: true);
      online = false;
      now = now.add(const Duration(minutes: 16));
      final data = await client.loadCatalog(na: true, force: true);
      expect(data['_stale'], isTrue);
      expect(releasesFor(data, 'OP 15', 'NA').map((entry) => entry['id']), [
        'rebuilt',
        'official',
      ]);
    });
  });

  group('CatalogClient routes', () {
    test('resolve posts the release to /api/resolve', () async {
      final entry = release();
      final transport = FakeTransport(
        (method, uri, headers, body) async =>
            jsonResponse({'url': 'https://cdn.example/ota.zip?Expires=9'}),
      );
      final client = CatalogClient(
        transport: transport,
        base: Uri.parse('https://edge.example/'),
      );
      expect(
        await client.resolveLink(entry),
        'https://cdn.example/ota.zip?Expires=9',
      );
      final call = transport.calls.single;
      expect(call.method, 'POST');
      expect(call.uri, Uri.parse('https://edge.example/api/resolve'));
      expect(call.headers['Content-Type'], 'application/json');
      expect(jsonDecode(call.body), entry);
    });

    test('resolve failures use upstream messages', () async {
      for (final response in <CatalogResponse>[
        rawResponse('{'),
        jsonResponse(<String, Object?>{}),
        notModified(),
      ]) {
        final client = CatalogClient(
          transport: FakeTransport(
            (method, uri, headers, body) async => response,
          ),
        );
        await expectLater(
          () => client.resolveLink(release()),
          throwsA(isA<CatalogException>()),
        );
      }
    });

    test('default base keeps catalog and resolve same-origin', () async {
      final transport = FakeTransport((method, uri, headers, body) async {
        if (method == 'POST') return jsonResponse({'url': 'https://cdn/x.zip'});
        return jsonResponse(catalog([release()]));
      });
      final client = CatalogClient(transport: transport);
      await client.loadCatalog();
      await client.resolveLink(release());
      expect(transport.calls.first.uri.scheme, isEmpty);
      expect(transport.calls.first.uri.toString(), 'api/catalog?na=0');
      expect(transport.calls.last.uri.toString(), 'api/resolve');
    });

    test('findRelease reads the NA feed for OP 15 NA', () async {
      final transport = FakeTransport((method, uri, headers, body) async {
        if (uri.queryParameters['na'] == '1') {
          return jsonResponse(
            catalog([release(id: 'rebuilt', device: 'OP 15', region: 'NA')]),
          );
        }
        return jsonResponse(catalog([]));
      });
      final client = CatalogClient(transport: transport);
      final found = await client.findRelease('rebuilt', 'OP 15', 'NA');
      expect(found['device'], 'OP 15');
      expect(transport.calls, hasLength(2));
      expect(transport.calls.first.uri.queryParameters['na'], '1');
    });
  });
}
