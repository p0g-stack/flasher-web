import 'package:flasher_web_core/src/upstream/bloat_selection.dart';
import 'package:flasher_web_core/src/upstream/device_layout.dart';
import 'package:flasher_web_core/src/upstream/tables.dart';
import 'package:test/test.dart';

Map<String, Object?> tablesJson() => {
  'commit': 'abc123',
  'devices': {
    'Oneplus 13': '13',
    'Oneplus 13T': '13T',
    'Oneplus Ace 6': 'Ace6',
    'Oneplus Ace 6T': 'Ace6T',
    'Realme GT 7 Pro': 'GT7Pro',
    'OPPO Find X9 Ultra': 'X9U',
  },
  'region_sizes': {
    '13': [15354134528, 15354134528],
    'X9U': [19671285760, 20451426304],
  },
  'builders': [
    ['SuperHybrid Flasher', '13', 'NA', 'BUILD_SUPER.sh'],
    ['SuperHybrid Flasher', '13', 'GLO', 'BUILD_SUPER.sh'],
    ['SuperHybrid Flasher', '13', 'CN', 'BUILD_SUPER.sh'],
    ['SuperHybrid Flasher', '13', 'EU', 'BUILD_SUPER.sh'],
    ['SuperHybrid Flasher', '13', 'IN', 'BUILD_SUPER.sh'],
    ['SuperHybrid Flasher', 'Ace6', 'CN', 'BUILD_SUPER.sh'],
    ['SuperHybrid Flasher', 'Ace6', 'IN', 'BUILD_ACE6_OOS.sh'],
    ['Super Flasher', '13T', 'CN', 'BUILD_SUPER.sh'],
    ['Super Flasher', '13T', 'IN', 'BUILD_SUPER.sh'],
    ['Super Flasher', 'Ace6T', 'CN', 'BUILD_SUPER.sh'],
    ['Super Flasher', 'Ace6T', 'IN', 'BUILD_SUPER.sh'],
    ['Super Flasher', 'Ace6T', 'GLO', 'BUILD_SUPER.sh'],
    ['Super Flasher', 'GT7Pro', 'CN', 'BUILD_SUPER.sh'],
    ['Super Flasher', 'GT7Pro', 'EU', 'BUILD_SUPER.sh'],
    for (final region in [
      'VN',
      'TW',
      'TH',
      'SG',
      'MY',
      'MX',
      'JP',
      'IN',
      'ID',
      'EU',
      'CN',
      'APC',
    ])
      ['Super Flasher', 'X9U', region, 'BUILD_SUPER.sh'],
    for (final region in [
      'VN',
      'TW',
      'TH',
      'SG',
      'MY',
      'MX',
      'JP',
      'IN',
      'ID',
      'EU',
      'CN',
      'APC',
    ])
      ['Regional Flasher', 'X9U', region, 'BUILD_REGIONAL.sh'],
  ],
};

Map<String, dynamic> manifest(List<String> paths) => {
  'files': {for (final path in paths) path: 'hash'},
};

void main() {
  group('UpstreamTables', () {
    final tables = UpstreamTables.fromJson(tablesJson());

    test('types keep workflow order and regions keep the standard order', () {
      expect(tables.devices['OPPO Find X9 Ultra'], 'X9U');
      expect(tables.types('OPPO Find X9 Ultra'), [
        'Super Flasher',
        'Regional Flasher',
      ]);
      expect(tables.regions('Oneplus 13', 'SuperHybrid Flasher'), [
        'GLO',
        'EU',
        'IN',
        'NA',
        'CN',
      ]);
      expect(tables.regions('OPPO Find X9 Ultra', 'Super Flasher'), [
        'APC',
        'CN',
        'EU',
        'ID',
        'IN',
        'JP',
        'MX',
        'MY',
        'SG',
        'TH',
        'TW',
        'VN',
      ]);
    });

    test('super sizes use CN and other columns and default to zero', () {
      expect(tables.superSize('13', 'CN'), 15354134528);
      expect(tables.superSize('13', 'GLO'), 15354134528);
      expect(tables.superSize('X9U', 'CN'), 19671285760);
      expect(tables.superSize('X9U', 'EU'), 20451426304);
      expect(tables.superSize('Pad3', 'GLO'), 0);
    });

    test('selection carries the builder and the ColorOS template subtree', () {
      final selection = tables.selection(
        'OPPO Find X9 Ultra',
        'Super Flasher',
        'CN',
      );
      expect(selection.dev, 'X9U');
      expect(selection.kind, 'Super Flasher');
      expect(selection.region, 'CN');
      expect(selection.device, 'OPPO Find X9 Ultra');
      expect(selection.builder, 'BUILD_SUPER.sh');
      expect(selection.subtree, 'cos');
      expect(selection.template, 'cos/super');
      expect(selection.imageFolder, 'OTA_FILES_HERE');
      expect(selection.coloros, isTrue);

      final oos = tables.selection('Oneplus 13', 'SuperHybrid Flasher', 'GLO');
      expect(oos.subtree, 'oos');
      expect(oos.template, 'oos/super');
      expect(oos.imageFolder, 'OOS_FILES_HERE');
      expect(oos.coloros, isFalse);

      final regional = tables.selection(
        'Oneplus 13',
        'SuperHybrid Flasher',
        'IN',
      );
      expect(regional.template, 'oos/super');
      final aceOos = tables.selection(
        'Oneplus Ace 6',
        'SuperHybrid Flasher',
        'IN',
      );
      expect(aceOos.builder, 'BUILD_ACE6_OOS.sh');
    });

    test('unsupported combinations raise upstream messages', () {
      expect(
        () => tables.selection('Oneplus 13', 'Regional Flasher', 'GLO'),
        throwsA(
          isA<UpstreamException>().having(
            (error) => error.message,
            'message',
            'This device, flasher type and region combination is unsupported.',
          ),
        ),
      );
      expect(
        () => tables.selection('Unknown', 'Super Flasher', 'CN'),
        throwsA(isA<UpstreamException>()),
      );
    });

    test('an empty workflow table is rejected', () {
      expect(
        () => UpstreamTables.fromJson({
          'devices': <String, String>{},
          'region_sizes': <String, Object?>{},
          'builders': <Object?>[],
        }),
        throwsA(
          isA<UpstreamException>().having(
            (error) => error.message,
            'message',
            'The workflow device/builder tables could not be read.',
          ),
        ),
      );
    });

    test('layout rules match upstream', () {
      expect(coloros('X9U', 'IN'), isTrue);
      expect(coloros('13', 'CN'), isTrue);
      expect(coloros('13', 'EU'), isFalse);
      expect(templateSubtree('13', 'CN'), 'cos');
      expect(templateSubtree('13', 'EU'), 'oos');
      expect(imageFolder('X9U', 'CN'), 'OTA_FILES_HERE');
      expect(imageFolder('13', 'CN'), 'COS_FILES_HERE');
      expect(imageFolder('13', 'EU'), 'OOS_FILES_HERE');
    });
  });

  group('selectedPaths', () {
    test('X9U CN reads EU_BLOAT, never CN_BLOAT or another device', () {
      final files = manifest([
        'bloat/X9U/EU_BLOAT/abl-16.0.6.img',
        'bloat/X9U/EU_BLOAT/my_preload.img',
        'bloat/X9U/CN_BLOAT/ignored.img',
        'bloat/X9U/IN_BLOAT/ignored.img',
        'bloat/13/EU_BLOAT/ignored.img',
      ]);
      final paths = selectedPaths(
        files,
        const Selection(dev: 'X9U', kind: 'Super Flasher', region: 'CN'),
      );
      expect(paths, [
        'bloat/X9U/EU_BLOAT/abl-16.0.6.img',
        'bloat/X9U/EU_BLOAT/my_preload.img',
      ]);
      expect(bloatFolder('X9U', 'Super Flasher', 'CN'), 'EU_BLOAT');
    });

    test('Ace 6 SuperHybrid IN reads OOS_BLOAT, not IN_BLOAT', () {
      final files = manifest([
        'bloat/Ace6/OOS_BLOAT/system_dlkm_oki.img',
        'bloat/Ace6/OOS_BLOAT/odm.img',
        'bloat/Ace6/IN_BLOAT/wrong.img',
        'bloat/Ace6/CN_BLOAT/wrong.img',
      ]);
      final selection = const Selection(
        dev: 'Ace6',
        kind: 'SuperHybrid Flasher',
        region: 'IN',
      );
      expect(bloatFolder('Ace6', 'SuperHybrid Flasher', 'IN'), 'OOS_BLOAT');
      expect(selectedPaths(files, selection), [
        'bloat/Ace6/OOS_BLOAT/odm.img',
        'bloat/Ace6/OOS_BLOAT/system_dlkm_oki.img',
      ]);
      expect(bloatFolder('Ace6', 'Super Flasher', 'IN'), 'IN_BLOAT');
    });

    test('CN adds the GLO preload fallback for non-X9U devices', () {
      final files = manifest([
        'bloat/13/CN_BLOAT/my_company.img',
        'bloat/13/GLO_BLOAT/my_preload.img',
        'bloat/13/GLO_BLOAT/ignored.img',
      ]);
      expect(
        selectedPaths(
          files,
          const Selection(dev: '13', kind: 'SuperHybrid Flasher', region: 'CN'),
        ),
        [
          'bloat/13/CN_BLOAT/my_company.img',
          'bloat/13/GLO_BLOAT/my_preload.img',
        ],
      );
    });

    test('13 SuperHybrid outside CN adds the COS fixes', () {
      final files = manifest([
        'bloat/13/GLO_BLOAT/my_company.img',
        'bloat/13/COS_FILES_HERE/my_region.img',
        'bloat/13/COS_FILES_HERE/oplusstanvbk.img',
        'bloat/13/COS_FILES_HERE/ignored.img',
      ]);
      expect(
        selectedPaths(
          files,
          const Selection(
            dev: '13',
            kind: 'SuperHybrid Flasher',
            region: 'GLO',
          ),
        ),
        [
          'bloat/13/COS_FILES_HERE/my_region.img',
          'bloat/13/COS_FILES_HERE/oplusstanvbk.img',
          'bloat/13/GLO_BLOAT/my_company.img',
        ],
      );
    });

    test('13T and GT7Pro add only their listed FIXES', () {
      final files = manifest([
        'bloat/13T/IN_BLOAT/my_company.img',
        'bloat/13T/FIXES/my_region.img',
        'bloat/13T/FIXES/oplusstanvbk.img',
        'bloat/13T/FIXES/odm.img',
        'bloat/13T/FIXES/ignored.img',
        'bloat/GT7Pro/EU_BLOAT/my_company.img',
        'bloat/GT7Pro/FIXES/my_region.img',
        'bloat/GT7Pro/FIXES/oplusstanvbk.img',
        'bloat/GT7Pro/FIXES/odm.img',
      ]);
      expect(
        selectedPaths(
          files,
          const Selection(dev: '13T', kind: 'Super Flasher', region: 'IN'),
        ),
        [
          'bloat/13T/FIXES/my_region.img',
          'bloat/13T/FIXES/odm.img',
          'bloat/13T/FIXES/oplusstanvbk.img',
          'bloat/13T/IN_BLOAT/my_company.img',
        ],
      );
      expect(
        selectedPaths(
          files,
          const Selection(dev: 'GT7Pro', kind: 'Super Flasher', region: 'EU'),
        ),
        [
          'bloat/GT7Pro/EU_BLOAT/my_company.img',
          'bloat/GT7Pro/FIXES/my_region.img',
          'bloat/GT7Pro/FIXES/oplusstanvbk.img',
        ],
      );
    });

    test('Ace 6T IN/GLO excludes static ODM unless requested', () {
      final files = manifest([
        'bloat/Ace6T/IN_BLOAT/my_region.img',
        'bloat/Ace6T/IN_BLOAT/odm.img',
        'bloat/Ace6T/GLO_BLOAT/odm.img',
      ]);
      const selection = Selection(
        dev: 'Ace6T',
        kind: 'Super Flasher',
        region: 'IN',
      );
      expect(selectedPaths(files, selection), [
        'bloat/Ace6T/IN_BLOAT/my_region.img',
      ]);
      expect(selectedPaths(files, selection, staticOdm: true), [
        'bloat/Ace6T/IN_BLOAT/my_region.img',
        'bloat/Ace6T/IN_BLOAT/odm.img',
      ]);
      expect(
        selectedPaths(
          manifest(['bloat/Ace6T/CN_BLOAT/odm.img']),
          const Selection(dev: 'Ace6T', kind: 'Super Flasher', region: 'CN'),
        ),
        ['bloat/Ace6T/CN_BLOAT/odm.img'],
      );
    });

    test('invalid manifest identity values raise upstream messages', () {
      expect(
        () => selectedPaths(
          manifest([]),
          const Selection(dev: 'X9U!', kind: 'Super Flasher', region: 'CN'),
        ),
        throwsA(
          isA<UpstreamException>().having(
            (error) => error.message,
            'message',
            'Invalid device ID',
          ),
        ),
      );
      expect(
        () => selectedPaths(
          manifest([]),
          const Selection(dev: 'X9U', kind: 'Super Flasher', region: 'cn'),
        ),
        throwsA(
          isA<UpstreamException>().having(
            (error) => error.message,
            'message',
            'Invalid region code',
          ),
        ),
      );
    });
  });
}
