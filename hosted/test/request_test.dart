import 'package:flasher_web_hosted/src/errors.dart';
import 'package:flasher_web_hosted/src/request.dart';
import 'package:test/test.dart';

void main() {
  test('accepts exactly the documented shape', () {
    final request = parseJobRequest({
      'selection': {
        'device': 'Oneplus 13',
        'kind': 'SuperHybrid Flasher',
        'region': 'GLO',
      },
      'catalogId': 'release-1',
      'baseCatalogId': 'base-1',
      'vulnerableAbl': false,
    });
    expect(request.device, 'Oneplus 13');
    expect(request.kind, 'SuperHybrid Flasher');
    expect(request.region, 'GLO');
    expect(request.catalogId, 'release-1');
    expect(request.baseCatalogId, 'base-1');
    expect(request.vulnerableAbl, isFalse);
    expect(request.toJson()['selection'], request.selection());
  });

  test('rejects unknown top-level and selection fields', () {
    expect(
      () => parseJobRequest({
        'selection': {
          'device': 'Oneplus 13',
          'kind': 'SuperHybrid Flasher',
          'region': 'GLO',
        },
        'catalogId': 'release-1',
        'url': 'https://example.com/ota.zip',
      }),
      throwsA(isA<HostedException>()),
    );
    expect(
      () => parseJobRequest({
        'selection': {
          'device': 'Oneplus 13',
          'kind': 'SuperHybrid Flasher',
          'region': 'GLO',
          'file': 'ota.zip',
        },
        'catalogId': 'release-1',
      }),
      throwsA(isA<HostedException>()),
    );
  });

  test('rejects URLs, paths and control characters in ids', () {
    for (final value in [
      'https://example.com/ota.zip',
      '/tmp/ota.zip',
      'release/../1',
      'release?x=1',
      'release\u0000',
      '',
    ]) {
      expect(
        () => parseJobRequest({
          'selection': {
            'device': 'Oneplus 13',
            'kind': 'SuperHybrid Flasher',
            'region': 'GLO',
          },
          'catalogId': value,
        }),
        throwsA(isA<HostedException>()),
        reason: value,
      );
    }
  });

  test('rejects non-boolean vulnerableAbl and missing required fields', () {
    expect(
      () => parseJobRequest({
        'selection': {
          'device': 'Oneplus 13',
          'kind': 'SuperHybrid Flasher',
          'region': 'GLO',
        },
        'catalogId': 'release-1',
        'vulnerableAbl': 'true',
      }),
      throwsA(isA<HostedException>()),
    );
    expect(
      () => parseJobRequest({
        'selection': {'device': 'Oneplus 13'},
        'catalogId': 'release-1',
      }),
      throwsA(isA<HostedException>()),
    );
  });

  test('fingerprint is stable across map key order', () {
    final left = parseJobRequest({
      'catalogId': 'release-1',
      'selection': {
        'region': 'GLO',
        'device': 'Oneplus 13',
        'kind': 'SuperHybrid Flasher',
      },
    });
    final right = parseJobRequest({
      'selection': {
        'device': 'Oneplus 13',
        'kind': 'SuperHybrid Flasher',
        'region': 'GLO',
      },
      'catalogId': 'release-1',
    });
    expect(left.fingerprint, right.fingerprint);
  });
}
