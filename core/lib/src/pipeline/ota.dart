/// A full AB OTA read in place: ZIP metadata, `META-INF/com/android/metadata`
/// and the payload manifest only, never the payload bytes.
///
/// Port of `backend.describe_ota` and `backend.inspect_ota`, with the Rust ZIP
/// reader in place of `zipfile`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../rust/api/arb.dart';
import '../rust/api/payload.dart';
import '../rust/api/zip.dart';
import '../storage/storage.dart';
import 'errors.dart';

/// What [OtaArchive] learned about a package.
final class OtaInfo {
  const OtaInfo({
    required this.version,
    required this.payloadSize,
    required this.fields,
    required this.partitions,
    required this.stored,
    required this.length,
  });

  final String version;
  final int payloadSize;
  final Map<String, String> fields;

  /// Partition name to image size, in manifest order.
  final Map<String, int> partitions;

  /// `payload.bin` is uncompressed, so ranges can address its data.
  final bool stored;

  /// Size of the whole ZIP.
  final int length;
}

/// A validated full AB OTA over a [ByteSource].
final class OtaArchive {
  OtaArchive._({
    required this.source,
    required this.info,
    required this.manifest,
    required this.payloadDataOffset,
    required this.dataStart,
    required this.remote,
    required this.manifestSha256,
  });

  /// The source reads are made through; it re-resolves expired catalog links.
  final ByteSource source;

  final OtaInfo info;

  /// The parsed payload manifest.
  final Manifest manifest;

  /// Digest of the exact protobuf bytes, including operation data hashes.
  final String manifestSha256;

  /// Absolute ZIP offset of `payload.bin`'s data.
  final int payloadDataOffset;

  /// Payload offset where operation data starts.
  final int dataStart;

  /// Whether reads cross the network (as opposed to a local file or blob).
  final bool remote;

  int get length => info.length;
  Map<String, String> get fields => info.fields;
  String get version => info.version;
  Map<String, int> get partitions => info.partitions;
  bool get stored => info.stored;
  int get payloadSize => info.payloadSize;

  int? _virtualLimit;

  /// Validate once per archive/limit before exposing authenticated reads.
  void verifyVirtualReads({int maxOperationBytes = 64 << 20}) {
    if (_virtualLimit == maxOperationBytes) return;
    manifest.verifyVirtual(maxOperationBytes: BigInt.from(maxOperationBytes));
    _virtualLimit = maxOperationBytes;
  }

  static const int _tailLimit = 65557 + 20 + 56;
  static const int _maxMetadata = 1024 * 1024;
  static const int _maxManifest = 256 * 1024 * 1024;

  /// Reads and validates [source].
  ///
  /// [refresh] opens a fresh source for the same package; it is called when a
  /// range request fails with 403 or 410 (an expired signed link), at most
  /// three times.
  static Future<OtaArchive> open(
    ByteSource source, {
    bool remote = false,
    Future<ByteSource> Function()? refresh,
  }) async {
    final effective = refresh == null
        ? source
        : _RefreshableSource(source, refresh, remote: remote);
    try {
      final entries = await _readDirectory(effective);
      final payload = entries['payload.bin'];
      if (payload == null) {
        throw const BuildException(
          'Choose a full Android OTA ZIP containing payload.bin and metadata: '
          'payload.bin is missing.',
        );
      }
      final payloadSize = payload.uncompressedSize.toInt();
      if (payloadSize < 24) {
        throw const BuildException('The OTA payload is empty or truncated.');
      }
      if (payload.method != 0) {
        throw const BuildException(
          'This OTA compresses payload.bin inside the ZIP. Only OTAs with a '
          'stored payload.bin can be read in place.',
        );
      }
      final payloadDataOffset = await _dataOffset(effective, payload);

      final metadata = entries['META-INF/com/android/metadata'];
      if (metadata == null) {
        throw const BuildException(
          'Choose a full Android OTA ZIP containing payload.bin and metadata: '
          'META-INF/com/android/metadata is missing.',
        );
      }
      final fields = _metadata(
        await _entryBytes(effective, metadata, _maxMetadata),
      );
      if ((fields['ota-type'] ?? 'AB') != 'AB') {
        throw const BuildException(
          'This appears to be an incremental OTA. A FULL OTA is required.',
        );
      }

      final head = await effective.read(payloadDataOffset, 24);
      final PayloadHeader header;
      try {
        header = payloadHeader(
          head24: head,
          payloadSize: BigInt.from(payloadSize),
        );
      } on Object catch (error) {
        throw BuildException(
          'payload.bin has an invalid Android payload header: $error',
        );
      }
      final manifestLength = header.manifestLen.toInt();
      if (manifestLength <= 0 || manifestLength > _maxManifest) {
        throw const BuildException('payload.bin has an invalid manifest.');
      }
      // `data_start` is where operation data begins; the manifest sits right
      // after the fixed header, before the metadata signature.
      final manifestOffset =
          header.dataStart.toInt() -
          manifestLength -
          header.signatureLen.toInt();
      final manifestBytes = await effective.read(
        payloadDataOffset + manifestOffset,
        manifestLength,
      );
      final Manifest manifest;
      try {
        manifest = Manifest.parse(manifest: manifestBytes);
      } on Object catch (error) {
        throw BuildException('payload.bin has an invalid manifest: $error');
      }
      final parts = manifest.partitions();
      if (parts.isEmpty) {
        throw const BuildException(
          'payload.bin has an invalid manifest: no partition images',
        );
      }
      final partitions = <String, int>{
        for (final part in parts) part.name: part.size.toInt(),
      };

      if (fields.containsKey('pre-build') ||
          fields.containsKey('pre-build-incremental')) {
        try {
          manifest.verifyFull();
        } on Object catch (error) {
          throw BuildException(
            'This appears to be an incremental OTA. A FULL OTA is required: $error',
          );
        }
      }

      final info = OtaInfo(
        version: _version(fields),
        payloadSize: payloadSize,
        fields: fields,
        partitions: partitions,
        stored: true,
        length: effective.length,
      );
      return OtaArchive._(
        source: effective,
        info: info,
        manifest: manifest,
        payloadDataOffset: payloadDataOffset,
        dataStart: header.dataStart.toInt(),
        remote: remote,
        manifestSha256: crypto.sha256.convert(manifestBytes).toString(),
      );
    } on Object {
      // A source opened only for inspection must not leak its handle.
      if (identical(effective, source)) {
        // The caller owns the source's lifetime.
      } else {
        await _close(effective);
      }
      rethrow;
    }
  }

  /// Operation bytes at [offset] (relative to the payload data start).
  Future<Uint8List> readPayloadData(int offset, int length) {
    if (offset < 0 || length < 0) {
      throw RangeError('negative payload range');
    }
    return source.read(payloadDataOffset + dataStart + offset, length);
  }

  /// The ARB index from `xbl_config`, or null when the image is absent or is
  /// not a recognised ELF64 xbl_config.
  Future<Map<String, int>?> arb() async {
    final size = partitions['xbl_config'];
    if (size == null || size <= 0) return null;
    try {
      final image = Uint8List(size);
      final ops = manifest.operations(name: 'xbl_config');
      for (final op in ops) {
        if (op.dataLength.toInt() > 0) {
          final data = await readPayloadData(
            op.dataOffset.toInt(),
            op.dataLength.toInt(),
          );
          final decoded = manifest.decodeOp(
            name: 'xbl_config',
            index: op.index,
            data: data,
          );
          var position = 0;
          for (final extent in op.dst) {
            final length = extent.length.toInt();
            if (position + length > decoded.length) {
              throw const BuildException(
                'xbl_config operation length mismatch',
              );
            }
            image.setRange(
              extent.offset.toInt(),
              extent.offset.toInt() + length,
              decoded,
              position,
            );
            position += length;
          }
        }
      }
      final info = arbScan(image: image);
      return {'major': info.major, 'minor': info.minor, 'index': info.index};
    } on BuildException {
      rethrow;
    } on Object {
      return null;
    }
  }

  Future<void> close() async {
    await _close(source);
  }

  static Future<void> _close(ByteSource source) => closeByteSource(source);

  static Future<Map<String, ZipEntry>> _readDirectory(ByteSource source) async {
    final length = source.length;
    final tailLength = length < _tailLimit ? length : _tailLimit;
    final tail = await source.read(length - tailLength, tailLength);
    final ZipDirectory directory;
    try {
      directory = zipEntries(tail: tail, fileLen: BigInt.from(length));
    } on Object catch (error) {
      throw BuildException(
        'Choose a full Android OTA ZIP containing payload.bin and metadata: $error',
      );
    }
    var entries = directory.entries;
    final needs = directory.needs;
    if (needs != null) {
      final offset = needs.$1.toInt();
      final size = needs.$2.toInt();
      if (offset < 0 || size < 0 || offset + size > length) {
        throw const BuildException(
          'The OTA ZIP central directory is out of range.',
        );
      }
      entries = zipParseCentral(cd: await source.read(offset, size));
    }
    return {for (final entry in entries) entry.name: entry};
  }

  static Future<int> _dataOffset(ByteSource source, ZipEntry entry) async {
    final header = await source.read(entry.localHeaderOffset.toInt(), 30);
    try {
      return zipDataOffset(
        localHeader30Bytes: header,
        localHeaderOffset: entry.localHeaderOffset,
      ).toInt();
    } on Object catch (error) {
      throw BuildException('The OTA ZIP entry is invalid: $error');
    }
  }

  static Future<Uint8List> _entryBytes(
    ByteSource source,
    ZipEntry entry,
    int limit,
  ) async {
    final size = entry.uncompressedSize.toInt();
    final compressed = entry.compressedSize.toInt();
    if (size > limit || compressed > limit) {
      throw const BuildException('The OTA metadata is too large.');
    }
    final offset = await _dataOffset(source, entry);
    final bytes = await source.read(offset, compressed);
    if (entry.method == 0) {
      if (bytes.length != size) {
        throw const BuildException('The OTA ZIP entry is truncated.');
      }
      return bytes;
    }
    if (entry.method != 8) {
      throw BuildException(
        'Unsupported OTA ZIP compression method ${entry.method}.',
      );
    }
    try {
      return inflateRaw(data: bytes, expectedLen: BigInt.from(size));
    } on Object catch (error) {
      throw BuildException('The OTA ZIP entry could not be read: $error');
    }
  }

  static Map<String, String> _metadata(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: false);
    final fields = <String, String>{};
    for (final line in const LineSplitter().convert(text)) {
      final index = line.indexOf('=');
      if (index < 0) continue;
      fields[line.substring(0, index)] = line.substring(index + 1);
    }
    return fields;
  }

  static final _versionPattern = RegExp(r'\d+(?:\.\d+){1,4}');
  static final _unsafeVersion = RegExp(r'[^\w.()+-]');

  static String _version(Map<String, String> fields) {
    final raw =
        fields['version_name'] ??
        fields['ota_version'] ??
        fields['post-build-incremental'] ??
        '';
    final matches = _versionPattern.allMatches(raw).toList();
    final version = matches.isEmpty
        ? raw.replaceAll(_unsafeVersion, '_')
        : matches
              .map((match) => match.group(0)!)
              .reduce((a, b) => a.length >= b.length ? a : b);
    if (version.isEmpty) {
      throw const BuildException(
        'No version_name, ota_version or post-build-incremental found in OTA '
        'metadata.',
      );
    }
    return version.length > 80 ? version.substring(0, 80) : version;
  }
}

/// A source whose signed link can expire: on 403/410 it opens a fresh one.
final class _RefreshableSource implements ByteSource {
  _RefreshableSource(this._current, this._refresh, {required this.remote})
    : length = _current.length;

  ByteSource _current;
  final Future<ByteSource> Function() _refresh;
  final bool remote;

  @override
  final int length;

  int _refreshes = 0;
  static const int _maxRefreshes = 3;
  static final _expired = RegExp(r'\b(403|410)\b');

  @override
  Future<Uint8List> read(int offset, int length) async {
    while (true) {
      try {
        return await _current.read(offset, length);
      } on Object catch (error) {
        if (!_isExpired(error) || _refreshes >= _maxRefreshes) rethrow;
        _refreshes++;
        final replacement = await _refresh();
        if (replacement.length != this.length) {
          throw const BuildException(
            'The OTA server reports a different file size than before. Fetch '
            'versions again and retry.',
          );
        }
        _current = replacement;
      }
    }
  }

  static bool _isExpired(Object error) {
    if (error is BuildException) return false;
    return _expired.hasMatch(error.toString());
  }

  Future<void> close() => closeByteSource(_current);
}
