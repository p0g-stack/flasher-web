import 'package:flasher_web/setup/setup_state.dart';
import 'package:flasher_web_core/flasher_web_core.dart' show otaEntryDigest;
import 'package:flutter_test/flutter_test.dart';

import 'fake.dart';

const _gib = 1024 * 1024 * 1024;
const _mib = 1024 * 1024;
const _size = 8 * _gib + 80 * _mib;
const _entry = <String, dynamic>{
  'id': 'ota-budget',
  'device': 'OP 13',
  'version': 'release',
  'size': _size,
};

Future<SetupState> _setup({
  required int available,
  List<Map<String, Object?>> items = const [],
}) async {
  final harness = Harness();
  harness.api.storageBudgetResult = {
    'cap': 10 * _gib,
    'usage': 10 * _gib - available,
    'quota': 64 * _gib,
    'available': available,
    'items': items,
  };
  final setup = SetupState(
    runtime: harness.runtime,
    tables: harness.tables,
    environment: harness.environment,
    preferences: harness.preferences,
  );
  addTearDown(setup.dispose);
  await pumpEventQueue();
  await setup.refreshBudget();
  return setup;
}

Map<String, Object?> _partial({
  required int allocated,
  int bytes = 32 * _mib,
}) => {
  'key': otaEntryDigest(_entry),
  'label': 'Partial OTA',
  'bytes': bytes,
  'allocated': allocated,
  'complete': false,
};

void main() {
  test(
    'a sparse partial OTA fits using its already charged allocation',
    () async {
      final setup = await _setup(
        available: 2 * _gib,
        items: [_partial(allocated: 8 * _gib)],
      );
      expect(setup.otaFitsCache(_entry), isTrue);
      expect(
        setup.cachedOtas.single['bytes'],
        32 * _mib,
        reason: 'downloaded progress remains distinct from file allocation',
      );
      expect(setup.isOtaCached(_entry), isFalse);
    },
  );

  test(
    'allocation is credited only to the matching catalog entry key',
    () async {
      final setup = await _setup(
        available: 2 * _gib,
        items: [_partial(allocated: 8 * _gib)],
      );
      expect(
        setup.otaFitsCache({..._entry, 'version': 'different-release'}),
        isFalse,
      );
    },
  );

  for (final available in [80 * _mib, 80 * _mib - 1]) {
    test('only the additional extent must fit: available=$available', () async {
      final setup = await _setup(
        available: available,
        items: [_partial(allocated: 8 * _gib)],
      );
      expect(setup.otaFitsCache(_entry), available == 80 * _mib);
    });
  }

  test(
    'a fully allocated partial OTA resumes with no free additional space',
    () async {
      final setup = await _setup(
        available: 0,
        items: [_partial(allocated: _size)],
      );
      expect(setup.otaFitsCache(_entry), isTrue);
    },
  );

  test(
    'durable bytes do not substitute for a missing file allocation',
    () async {
      final setup = await _setup(
        available: 2 * _gib,
        items: [_partial(allocated: 0, bytes: _size)],
      );
      expect(setup.otaFitsCache(_entry), isFalse);
    },
  );

  test('a fresh OTA still needs its full catalog size', () async {
    final setup = await _setup(available: 2 * _gib);
    expect(setup.otaFitsCache(_entry), isFalse);
    expect(setup.otaFitsCache({..._entry, 'size': 2 * _gib}), isTrue);
  });
}
