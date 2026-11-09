/// Read-only OTA images reconstructed in memory, never in a workspace.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../pipeline/ota.dart';
import '../rust/api/payload.dart';
import 'model.dart';
import 'package.dart';

/// One package-wide decoded-operation cache (at most 64 MiB).
final class OtaOperationCache {
  OtaOperationCache({this.limit = 64 << 20}) {
    if (limit <= 0 || limit > 64 << 20) {
      throw ArgumentError.value(limit, 'limit');
    }
  }
  final int limit;
  final Map<String, Uint8List> _entries = {};
  int _bytes = 0;
  int get bytes => _bytes;
  int peakBytes = 0;
  Future<void> _pending = Future.value();
  String? _aheadKey;
  Future<Uint8List?>? _ahead;

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> close() async {
    await _pending;
    await _ahead;
    _ahead = null;
    _aheadKey = null;
    clear();
  }

  Uint8List? get(String key) {
    final found = _entries.remove(key);
    if (found != null) _entries[key] = found;
    return found;
  }

  void reserve(int count) {
    if (count > limit) {
      throw FlashException('OTA operation needs $count decoded bytes; virtual limit is $limit.');
    }
    while (_bytes + count > limit && _entries.isNotEmpty) {
      _bytes -= _entries.remove(_entries.keys.first)!.length;
    }
  }

  void put(String key, Uint8List bytes) {
    final previous = _entries.remove(key);
    if (previous != null) _bytes -= previous.length;
    reserve(bytes.length);
    _entries[key] = bytes;
    _bytes += bytes.length;
    peakBytes = math.max(peakBytes, _bytes);
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }
}

final class _Span {
  const _Span(this.offset, this.length, this.op, this.decodedOffset);
  final int offset;
  final int length;
  final OpInfo op;
  final int decodedOffset;
}

/// Validates coverage in destination order, not payload operation order.
final class OtaPartitionSource implements FlashSource {
  OtaPartitionSource({required this.ota, required this.partition, required this.cache}) {
    ota.verifyVirtualReads(maxOperationBytes: cache.limit);
    final ops = ota.manifest.operations(name: partition.name);
    for (final op in ops) {
      var decodedOffset = 0;
      for (final extent in op.dst) {
        final count = extent.length.toInt();
        _spans.add(_Span(extent.offset.toInt(), count, op, decodedOffset));
        decodedOffset += count;
      }
      _totals[op.index] = decodedOffset;
      if (op.dataOffset.toInt() < 0 || op.dataLength.toInt() < 0 ||
          op.dataOffset.toInt() + op.dataLength.toInt() > ota.payloadSize - ota.dataStart) {
        throw FlashException('${partition.name}.img operation ${op.index} has an invalid payload range.');
      }
      if (op.kind != 6 && op.kind != 7 && decodedOffset > cache.limit) {
        throw FlashException('${partition.name}.img operation ${op.index} exceeds the decoded cache limit.');
      }
    }
    _spans.sort((a, b) => a.offset.compareTo(b.offset));
    var end = 0;
    for (final span in _spans) {
      if (span.length <= 0 || span.offset != end) {
        throw FlashException('${partition.name}.img has overlapping or incomplete destination extents.');
      }
      end += span.length;
    }
    if (end != length) {
      throw FlashException('${partition.name}.img is incomplete ($end != $length).');
    }
  }

  final OtaArchive ota;
  final PartitionInfo partition;
  final OtaOperationCache cache;
  final _spans = <_Span>[];
  final _totals = <int, int>{};
  bool _closed = false;
  @override
  int get length => partition.size.toInt();

  Future<Uint8List> _decode(OpInfo op, OpInfo? next) =>
      cache._exclusive(() => _decodeOne(op, next));

  Future<Uint8List> _decodeOne(OpInfo op, OpInfo? next) async {
    final key = '${ota.manifestSha256}/${partition.name}/${op.index}';
    final cached = cache.get(key);
    if (cached != null) return cached;
    Uint8List? encoded;
    final ahead = cache._ahead;
    if (ahead != null) {
      final data = await ahead;
      if (cache._aheadKey == key) encoded = data;
      cache._ahead = null;
      cache._aheadKey = null;
    }
    encoded ??= await ota.readPayloadData(op.dataOffset.toInt(), op.dataLength.toInt());
    if (ota.remote && next != null && next.index != op.index &&
        next.dataLength.toInt() > 0 && next.dataLength.toInt() <= 8 << 20 &&
        cache.get('${ota.manifestSha256}/${partition.name}/${next.index}') == null) {
      cache._aheadKey = '${ota.manifestSha256}/${partition.name}/${next.index}';
      cache._ahead = ota.readPayloadData(next.dataOffset.toInt(), next.dataLength.toInt())
          .then<Uint8List?>((data) => data, onError: (Object _) => null);
    }
    final expected = _totals[op.index]!;
    cache.reserve(op.kind == 6 || op.kind == 7 ? 0 : expected);
    try {
      final decoded = ota.manifest.decodeOp(name: partition.name, index: op.index, data: encoded);
      if (decoded.isNotEmpty && decoded.length != expected) {
        throw FlashException('${partition.name}.img operation ${op.index} has the wrong length.');
      }
      if (decoded.isEmpty && op.kind != 6 && op.kind != 7) {
        throw FlashException('${partition.name}.img operation ${op.index} unexpectedly decoded no data.');
      }
      cache.put(key, decoded);
      return decoded;
    } on FlashException {
      rethrow;
    } on Object catch (error) {
      throw FlashException('${partition.name}.img operation ${op.index}: $error');
    }
  }

  int _find(int offset) {
    var low = 0;
    var high = _spans.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_spans[mid].offset + _spans[mid].length <= offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (_closed) throw StateError('OTA image source is closed.');
    if (offset < 0 || length < 0 || offset + length > this.length) {
      throw RangeError('Invalid OTA image range: $offset + $length / ${this.length}');
    }
    // Callers cannot accidentally materialize a complete multi-GiB image.
    if (length > 8 << 20) throw RangeError('OTA image reads are limited to 8 MiB.');
    final result = Uint8List(length);
    var written = 0;
    var index = _find(offset);
    while (written < length) {
      final span = _spans[index];
      final within = offset + written - span.offset;
      final count = math.min(length - written, span.length - within);
      final decoded = await _decode(span.op, index + 1 < _spans.length ? _spans[index + 1].op : null);
      if (decoded.isNotEmpty) {
        final start = span.decodedOffset + within;
        result.setRange(written, written + count, decoded, start);
      }
      written += count;
      index++;
    }
    return result;
  }

  @override
  Stream<Uint8List> stream({int chunkSize = 1 << 20}) async* {
    if (chunkSize <= 0 || chunkSize > 8 << 20) throw ArgumentError.value(chunkSize, 'chunkSize');
    for (var offset = 0; offset < length; offset += chunkSize) {
      yield await read(offset, math.min(chunkSize, length - offset));
    }
  }

  @override
  Future<FlashCursor> cursor() async => RandomFlashCursor(this);
  @override
  Future<void> close() async {
    _closed = true;
    await cache._pending;
    await cache._ahead;
  }
}

/// Forward cursor for a bounded random-access source. Does not own the source.
final class RandomFlashCursor implements FlashCursor {
  RandomFlashCursor(this.source);
  final FlashSource source;
  int _position = 0;
  @override
  Future<Uint8List> readExact(int length) async {
    final bytes = await source.read(_position, length);
    _position += length;
    return bytes;
  }
  @override
  Future<void> skipTo(int offset) async {
    if (offset < _position || offset > source.length) throw RangeError('Invalid forward cursor offset.');
    _position = offset;
  }
  @override
  Future<void> close() async {}
}
