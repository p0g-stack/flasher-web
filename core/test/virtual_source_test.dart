import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:flasher_web_core/src/rust/api/payload.dart' show Sha256Hasher;
import 'package:test/test.dart';

import 'ota_fixture.dart';

void main() {
  setUpAll(() async {
    expect(await loadNative(), isTrue);
  });

  late Directory temp;
  late IoWorkspace workspace;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('virtual_source_');
    workspace = IoWorkspace(temp);
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('every mixed-OTA image equals the manifest for read, stream and cursor', () async {
    final fixtures = IoWorkspace(Directory('test/fixtures'));
    final source = await fixtures.open('mixed-ota.zip');
    final OtaArchive ota;
    try {
      ota = await OtaArchive.open(source);
    } on Object {
      await closeByteSource(source);
      rethrow;
    }
    try {
      final cache = OtaOperationCache();
      try {
        final parts = ota.manifest.partitions();
        expect(parts, isNotEmpty);
        for (final part in parts) {
          final image = OtaPartitionSource(
            ota: ota,
            partition: part,
            cache: cache,
          );
          // One whole read is the reference: it is hash-checked against the
          // payload manifest below, so every later comparison uses verified
          // bytes.
          final expected = await image.read(0, image.length);
          expect(expected.length, part.size.toInt());
          if (part.sha256 != null) {
            expect(part.sha256, sha256.convert(expected).toString());
          }
          try {
            expect(image.length, expected.length);

            // Whole read, then odd-sized reads that split operations.
            expect(await image.read(0, expected.length), expected);
            for (final chunk in [777, 3 * 1024 + 5, 4096]) {
              var offset = 0;
              final built = BytesBuilder(copy: false);
              while (offset < expected.length) {
                final take = math.min(chunk, expected.length - offset);
                built.add(await image.read(offset, take));
                offset += take;
              }
              expect(
                built.takeBytes(),
                expected,
                reason: '${part.name} chunked reads of $chunk bytes',
              );
            }

            // Random reads, deterministic through one seed.
            var state = 12345 + part.name.length;
            for (var round = 0; round < 24; round++) {
              state = (state * 1103515245 + 12345) & 0x7fffffff;
              final offset = state % expected.length;
              final limit = math.min(4096, expected.length - offset);
              state = (state * 1103515245 + 12345) & 0x7fffffff;
              final length = 1 + state % limit;
              expect(
                await image.read(offset, length),
                Uint8List.sublistView(expected, offset, offset + length),
                reason: '${part.name} random read at $offset + $length',
              );
            }

            // Sequential stream.
            final streamed = BytesBuilder(copy: false);
            await for (final chunk in image.stream(chunkSize: 1000)) {
              expect(chunk.length, lessThanOrEqualTo(1000));
              streamed.add(chunk);
            }
            expect(streamed.takeBytes(), expected);

            // Forward cursor with skips over the decoded spans.
            final cursor = await image.cursor();
            try {
              var position = 0;
              while (position < expected.length) {
                final take = math.min(1024, expected.length - position);
                expect(
                  await cursor.readExact(take),
                  Uint8List.sublistView(expected, position, position + take),
                  reason: '${part.name} cursor read at $position',
                );
                position += take;
                if (position < expected.length) {
                  final skip = math.min(2048, expected.length - position);
                  await cursor.skipTo(position + skip);
                  position += skip;
                }
              }
              expect(
                () => cursor.skipTo(position - 1),
                throwsA(isA<RangeError>()),
                reason: 'a cursor never moves backwards',
              );
            } finally {
              await cursor.close();
            }
          } finally {
            await image.close();
          }
        }
      } finally {
        await cache.close();
      }
    } finally {
      await ota.close();
    }
  });

  test('two sources sharing one cache still read their own bytes', () async {
    final fixtures = IoWorkspace(Directory('test/fixtures'));
    final source = await fixtures.open('mixed-ota.zip');
    final ota = await OtaArchive.open(source);
    try {
      final cache = OtaOperationCache();
      final parts = ota.manifest.partitions();
      final sources = [
        for (final part in parts)
          OtaPartitionSource(ota: ota, partition: part, cache: cache),
      ];
      try {
        for (var index = 0; index < parts.length; index++) {
          final part = parts[index];
          final image = sources[index];
          final expected = await image.read(0, image.length);
          if (part.sha256 != null) {
            expect(part.sha256, sha256.convert(expected).toString());
          }
          final built = BytesBuilder(copy: false);
          for (var offset = 0; offset < expected.length; offset += 512) {
            built.add(
              await image.read(offset, math.min(512, expected.length - offset)),
            );
          }
          expect(built.takeBytes(), expected, reason: part.name);
        }
      } finally {
        for (final image in sources) {
          await image.close();
        }
        await cache.close();
      }
    } finally {
      await ota.close();
    }
  });

  test(
    'an out-of-order payload decodes by destination extents, including ZERO',
    () async {
      final first = pattern(fixtureBlock, seed: 1);
      final second = pattern(fixtureBlock, seed: 2);
      final third = pattern(fixtureBlock, seed: 3);
      final dtbo = FixturePartition(
        name: 'dtbo',
        ops: [
          // Destination extents out of order, and two extents in one op.
          FixtureOp.replace([
            const FixtureExtent(2, 1),
            const FixtureExtent(0, 1),
          ], Uint8List.fromList([...first, ...second])),
          FixtureOp.zero([const FixtureExtent(1, 1)]),
          FixtureOp.replace([const FixtureExtent(3, 1)], third),
        ],
      );
      final fixture = OtaFixture([dtbo], versionName: 'TEST_9.8.7');
      final bytes = fixture.build();
      final sink = await workspace.create('out-of-order.zip');
      await sink.write(bytes, 0);
      await sink.close();

      final source = await workspace.open('out-of-order.zip');
      final ota = await OtaArchive.open(source);
      try {
        // The image is built in destination order, not operation order.
        final expected = Uint8List.fromList([
          ...second,
          ...Uint8List(fixtureBlock),
          ...first,
          ...third,
        ]);
        expect(dtbo.image(), expected);
        expect(
          sha256.convert(expected).toString(),
          dtbo.sha256Hex,
          reason: 'the fixture must record the true image hash',
        );

        final part = ota.manifest.partitions().single;
        final image = OtaPartitionSource(
          ota: ota,
          partition: part,
          cache: OtaOperationCache(),
        );
        try {
          expect(await image.read(0, expected.length), expected);
          // A read spanning the ZERO extent and both REPLACE extents.
          final start = fixtureBlock - 100;
          expect(
            await image.read(start, fixtureBlock + 200),
            Uint8List.sublistView(expected, start, start + fixtureBlock + 200),
          );
          // A read that begins in the last extent of the first operation.
          expect(
            await image.read(2 * fixtureBlock + 10, 20),
            Uint8List.sublistView(
              expected,
              2 * fixtureBlock + 10,
              2 * fixtureBlock + 30,
            ),
          );
        } finally {
          await image.close();
        }
      } finally {
        await ota.close();
      }
    },
  );

  test('tampered operation data fails the read before any bytes', () async {
    final boot = FixturePartition(
      name: 'boot',
      ops: [
        FixtureOp.replace([
          const FixtureExtent(0, 1),
        ], pattern(fixtureBlock, seed: 7)),
      ],
    );
    final fixture = OtaFixture([boot]);
    final bytes = fixture.build();
    bytes[fixture.dataOffsetInZip('boot', 0)] ^= 0x5a;

    final sink = await workspace.create('tampered.zip');
    await sink.write(bytes, 0);
    await sink.close();
    final source = await workspace.open('tampered.zip');
    final ota = await OtaArchive.open(source);
    try {
      final image = OtaPartitionSource(
        ota: ota,
        partition: ota.manifest.partitions().single,
        cache: OtaOperationCache(),
      );
      try {
        await expectLater(
          image.read(0, fixtureBlock),
          throwsA(
            isA<FlashException>().having(
              (error) => error.message,
              'message',
              allOf(contains('boot.img operation 0'), contains('SHA-256')),
            ),
          ),
        );
      } finally {
        await image.close();
      }
    } finally {
      await ota.close();
    }
  });

  test('an operation without a data hash is refused before any read', () async {
    final boot = FixturePartition(
      name: 'boot',
      ops: [
        FixtureOp.replace([
          const FixtureExtent(0, 1),
        ], pattern(fixtureBlock, seed: 8), hash: false),
      ],
    );
    final fixture = OtaFixture([boot]);
    final sink = await workspace.create('unhashed.zip');
    await sink.write(fixture.build(), 0);
    await sink.close();
    final source = await workspace.open('unhashed.zip');
    final ota = await OtaArchive.open(source);
    try {
      expect(
        () => ota.verifyVirtualReads(),
        throwsA(
          predicate(
            (Object error) => '$error'.contains('no data SHA-256'),
            'an error naming the missing operation hash',
          ),
        ),
      );
      expect(
        () => OtaPartitionSource(
          ota: ota,
          partition: ota.manifest.partitions().single,
          cache: OtaOperationCache(),
        ),
        throwsA(
          predicate(
            (Object error) => '$error'.contains('no data SHA-256'),
            'an error naming the missing operation hash',
          ),
        ),
      );
    } finally {
      await ota.close();
    }
  });

  test('an image larger than the cache stays within the 64 MiB limit', () async {
    const blocks = 8448; // 33 MiB per operation: the image needs 66 MiB.
    final first = pattern(blocks * fixtureBlock, seed: 11);
    final second = pattern(blocks * fixtureBlock, seed: 12);
    final system = FixturePartition(
      name: 'system',
      ops: [
        FixtureOp.replace([const FixtureExtent(0, blocks)], first),
        FixtureOp.replace([const FixtureExtent(blocks, blocks)], second),
      ],
    );
    final fixture = OtaFixture([system]);
    final bytes = fixture.build();
    expect(bytes.length, greaterThan(64 << 20));
    final sink = await workspace.create('large.zip');
    await sink.write(bytes, 0);
    await sink.close();

    final source = await workspace.open('large.zip');
    final ota = await OtaArchive.open(source);
    final cache = OtaOperationCache();
    try {
      final image = OtaPartitionSource(
        ota: ota,
        partition: ota.manifest.partitions().single,
        cache: cache,
      );
      try {
        final hasher = Sha256Hasher();
        var offset = 0;
        while (offset < image.length) {
          final chunk = await image.read(
            offset,
            math.min(1 << 20, image.length - offset),
          );
          hasher.update(bytes: chunk);
          offset += chunk.length;
        }
        expect(hasher.finishHex(), system.sha256Hex);
        expect(cache.peakBytes, lessThanOrEqualTo(64 << 20));
        expect(cache.bytes, lessThanOrEqualTo(64 << 20));
      } finally {
        await image.close();
      }
    } finally {
      await cache.close();
      await ota.close();
    }
  });

  test('the operation cache rejects limits outside the contract', () {
    expect(() => OtaOperationCache(limit: 0), throwsArgumentError);
    expect(() => OtaOperationCache(limit: -1), throwsArgumentError);
    expect(() => OtaOperationCache(limit: (64 << 20) + 1), throwsArgumentError);
    expect(OtaOperationCache(limit: 64 << 20).limit, 64 << 20);
  });
}
