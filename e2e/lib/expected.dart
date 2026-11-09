/// The bytes a correct flash must produce, computed with the same core
/// pipeline natively.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

import 'fixture.dart';

/// A sparse image expanded to its present blocks.
final class ExpandedSparse {
  ExpandedSparse(this.blockSize, this.totalBlocks, this.blocks);

  final int blockSize;
  final int totalBlocks;

  /// Block index to its 4096-byte content; DONT_CARE blocks are absent.
  final Map<int, Uint8List> blocks;
}

/// Expands [sparse] the same way the harness reassembles recorded writes.
ExpandedSparse expandSparse(Uint8List sparse) {
  final data = ByteData.sublistView(sparse);
  if (data.getUint32(0, Endian.little) != 0xed26ff3a) {
    throw StateError('not a sparse image');
  }
  final blockSize = data.getUint32(12, Endian.little);
  final totalBlocks = data.getUint32(16, Endian.little);
  final chunks = data.getUint32(20, Endian.little);
  final blocks = <int, Uint8List>{};
  var offset = 28;
  var block = 0;
  for (var index = 0; index < chunks; index++) {
    final kind = data.getUint16(offset, Endian.little);
    final count = data.getUint32(offset + 4, Endian.little);
    final total = data.getUint32(offset + 8, Endian.little);
    final payload = total - 12;
    switch (kind) {
      case 0xcac1:
        if (payload != count * blockSize) {
          throw StateError('RAW chunk has the wrong size');
        }
        for (var within = 0; within < count; within++) {
          final start = offset + 12 + within * blockSize;
          blocks[block + within] = Uint8List.fromList(
            Uint8List.sublistView(sparse, start, start + blockSize),
          );
        }
      case 0xcac2:
        if (payload != 4) throw StateError('FILL chunk has the wrong size');
        final value = data.getUint32(offset + 12, Endian.little);
        final fill = Uint8List(blockSize);
        for (var p = 0; p < blockSize; p++) {
          fill[p] = (value >> ((p % 4) * 8)) & 0xff;
        }
        for (var within = 0; within < count; within++) {
          blocks[block + within] = Uint8List.fromList(fill);
        }
      case 0xcac3:
        if (payload != 0) throw StateError('DONT_CARE chunk has data');
      default:
        throw StateError('unexpected sparse chunk 0x${kind.toRadixString(16)}');
    }
    block += count;
    offset += total;
  }
  if (block != totalBlocks || offset != sparse.length) {
    throw StateError('sparse geometry does not match its length');
  }
  return ExpandedSparse(blockSize, totalBlocks, blocks);
}

/// Merges recorded `flash:super` parts into one block map.
///
/// Every part is a complete sparse image with its own header and DONT_CARE
/// chunks covering the blocks earlier parts wrote, so the parts are expanded
/// separately and merged by absolute block index.
ExpandedSparse mergeSparseParts(Iterable<String> encodedParts) {
  var blockSize = 0;
  var totalBlocks = 0;
  final blocks = <int, Uint8List>{};
  for (final encoded in encodedParts) {
    final part = expandSparse(base64Decode(encoded));
    if (blockSize == 0) {
      blockSize = part.blockSize;
      totalBlocks = part.totalBlocks;
    } else if (part.blockSize != blockSize ||
        part.totalBlocks != totalBlocks) {
      throw StateError('sparse parts disagree about the image geometry');
    }
    blocks.addAll(part.blocks);
  }
  return ExpandedSparse(blockSize, totalBlocks, blocks);
}

/// The package's expected images, computed natively from the same fixture.
final class ExpectedPackage {
  ExpectedPackage({
    required this.superBytes,
    required this.expandedSuper,
    required this.images,
    required this.receiptHashes,
    required this.exportZipPath,
  });

  /// `super.img` as the package streams it (sparse).
  final Uint8List superBytes;

  /// [superBytes] expanded.
  final ExpandedSparse expandedSuper;

  /// The other package images, by path, for example `OOS_FILES_HERE/boot.img`.
  final Map<String, Uint8List> images;

  /// The load-time `image_sha256` entries (Super inputs by decoded digest).
  final Map<String, String> receiptHashes;

  /// Where the native export wrote its ZIP.
  final String exportZipPath;

  static Future<ExpectedPackage> compute(E2eFixture fixture) async {
    final package = await fixture.virtual.open(
      e2eSelection,
      superSize: fixture.superSize,
    );
    try {
      final superBytes = await packageBytes(package, 'super.img');
      final images = <String, Uint8List>{};
      // Every top-level image in any image folder: OOS images and the COS
      // bloat images the template flashes beside the super.
      for (final path in package.index.entries) {
        final parts = path.split('/');
        if (parts.length != 2 || !path.endsWith('.img')) continue;
        if (path == 'super.img') continue;
        images[path] = await packageBytes(package, path);
      }
      final hashes = (package.buildJson['image_sha256']! as Map)
          .cast<String, String>();
      final dir = await Directory.systemTemp.createTemp('flasher-e2e-export-');
      final out = '${dir.path}/expected.zip';
      final sink = await IoWorkspace(dir).create('expected.zip');
      try {
        await for (final event in exportVirtualZip(
          package: package,
          upstream: UpstreamAssets(fixture.upstreamDir),
          sink: sink,
        )) {
          if (event['type'] == 'error') throw StateError('${event['message']}');
        }
      } finally {
        await sink.close();
      }
      return ExpectedPackage(
        superBytes: superBytes,
        expandedSuper: expandSparse(superBytes),
        images: images,
        receiptHashes: hashes,
        exportZipPath: out,
      );
    } finally {
      await package.close();
    }
  }
}

/// The entries of a flasher ZIP, name to bytes.
Map<String, Uint8List> zipEntryBytes(Uint8List zip) {
  final archive = ZipDecoder().decodeBytes(zip, verify: true);
  return {
    for (final entry in archive)
      if (entry.isFile) entry.name: Uint8List.fromList(entry.content as List<int>),
  };
}

/// SHA-256 as lowercase hex.
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// Equality of two byte lists.
bool sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
