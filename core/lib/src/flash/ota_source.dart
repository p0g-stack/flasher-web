/// Read-only OTA images reconstructed in memory, never in a workspace.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../pipeline/ota.dart';
import '../rust/api/payload.dart';
import 'model.dart';
import 'op_decoder.dart';
import 'package.dart';

/// One package-wide decoded-operation cache (at most 64 MiB), and the
/// decoder its sources use.
///
/// The limit covers decoded operations held for re-reads and those still
/// being decoded ahead of the reader, so the decoded bytes in memory never
/// pass it however many workers decode.
final class OtaOperationCache {
  OtaOperationCache({this.limit = 64 << 20, this.decoder = const InlineOpDecoder()}) {
    if (limit <= 0 || limit > 64 << 20) {
      throw ArgumentError.value(limit, 'limit');
    }
  }
  final int limit;

  /// Decodes the operations; [close] closes it with the cache.
  final OpDecoder decoder;
  final Map<String, Uint8List> _entries = {};
  int _bytes = 0;
  int _pending = 0;
  int get bytes => _bytes + _pending;
  int peakBytes = 0;

  Future<void> close() async {
    clear();
    await decoder.close();
  }

  Uint8List? get(String key) {
    final found = _entries.remove(key);
    if (found != null) _entries[key] = found;
    return found;
  }

  /// Room for [count] decoded bytes that are not in the cache yet, evicting
  /// the least recently used entries. False when operations already being
  /// decoded hold the rest of the limit.
  bool _reserve(int count) {
    if (count > limit) {
      throw FlashException('OTA operation needs $count decoded bytes; virtual limit is $limit.');
    }
    while (_bytes + _pending + count > limit && _entries.isNotEmpty) {
      _bytes -= _entries.remove(_entries.keys.first)!.length;
    }
    if (_bytes + _pending + count > limit) return false;
    _pending += count;
    peakBytes = math.max(peakBytes, bytes);
    return true;
  }

  void _release(int count) => _pending -= count;

  void put(String key, Uint8List bytes) {
    final previous = _entries.remove(key);
    if (previous != null) _bytes -= previous.length;
    while (_bytes + _pending + bytes.length > limit && _entries.isNotEmpty) {
      _bytes -= _entries.remove(_entries.keys.first)!.length;
    }
    _entries[key] = bytes;
    _bytes += bytes.length;
    peakBytes = math.max(peakBytes, this.bytes);
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
///
/// Reads in destination order keep a window of operations decoding ahead:
/// their payload data is fetched in ranges of up to [fetchBytes] that cover
/// several adjacent operations, and the cache's decoder works on as many of
/// them at once as it can. A read elsewhere restarts the window there.
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
      if (!_position.containsKey(span.op.index)) {
        _position[span.op.index] = _order.length;
        _order.add(span.op);
      }
    }
    if (end != length) {
      throw FlashException('${partition.name}.img is incomplete ($end != $length).');
    }
  }

  /// The largest payload range one fetch covers.
  static const int fetchBytes = 8 << 20;

  final OtaArchive ota;
  final PartitionInfo partition;
  final OtaOperationCache cache;
  final _spans = <_Span>[];
  final _totals = <int, int>{};

  /// Operations in destination order, and each one's place in it.
  final _order = <OpInfo>[];
  final _position = <int, int>{};

  /// Operations decoding ahead of the reader, by operation index.
  final _ahead = <int, Future<Uint8List>>{};

  /// Every fetch and decode still running, including ones a restart left.
  final _running = <Future<void>>{};
  int _next = 0;
  bool _closed = false;
  @override
  int get length => partition.size.toInt();

  late final int _blockSize = ota.manifest.blockSize().toInt();

  /// Operations decoding at once: enough to keep every decode worker busy
  /// while the next fetch is in flight.
  int get _window => math.max(2, cache.decoder.parallelism * 2);

  String _key(OpInfo op) => '${ota.manifestSha256}/${partition.name}/${op.index}';

  bool _decodes(OpInfo op) => op.kind != 6 && op.kind != 7;

  Future<Uint8List> _decode(OpInfo op) async {
    final cached = cache.get(_key(op));
    if (cached != null) return cached;
    if (!_ahead.containsKey(op.index)) {
      _restartAt(_position[op.index]!);
    }
    _fill();
    // Abandoned decodes may still hold the limit; the operation being read
    // goes ahead anyway, one past the limit at most.
    if (!_ahead.containsKey(op.index)) _schedule([op], reserved: false);
    final pending = _ahead.remove(op.index)!;
    try {
      final decoded = await pending;
      if (_decodes(op)) cache.put(_key(op), decoded);
      return decoded;
    } finally {
      if (!_closed) _fill();
    }
  }

  void _restartAt(int position) {
    // Operations decoding for an earlier position finish on their own and
    // release their reservations; nothing waits for them.
    _ahead.clear();
    _next = position;
  }

  /// Schedules fetches and decodes from [_next] until the window is full.
  void _fill() {
    while (_next < _order.length && _ahead.length < _window) {
      final group = <OpInfo>[];
      var end = -1;
      while (_next < _order.length && _ahead.length + group.length < _window) {
        final op = _order[_next];
        if (_ahead.containsKey(op.index) || cache.get(_key(op)) != null) {
          if (group.isNotEmpty) break;
          _next++;
          continue;
        }
        final offset = op.dataOffset.toInt();
        final size = op.dataLength.toInt();
        if (group.isNotEmpty && (offset != end || offset + size - group.first.dataOffset.toInt() > fetchBytes)) {
          break;
        }
        final need = _decodes(op) ? _totals[op.index]! : 0;
        if (need > 0 && !cache._reserve(need)) break;
        group.add(op);
        end = offset + size;
        _next++;
      }
      if (group.isEmpty) return;
      _schedule(group);
    }
  }

  void _schedule(List<OpInfo> group, {bool reserved = true}) {
    final start = group.first.dataOffset.toInt();
    final count = group.last.dataOffset.toInt() + group.last.dataLength.toInt() - start;
    final Future<Uint8List> fetched = count == 0
        ? Future.value(Uint8List(0))
        : ota.readPayloadData(start, count);
    for (final op in group) {
      final need = reserved && _decodes(op) ? _totals[op.index]! : 0;
      final result = fetched.then((data) {
        if (_closed) throw StateError('OTA image source is closed.');
        final from = op.dataOffset.toInt() - start;
        return _decodeOne(op, Uint8List.sublistView(data, from, from + op.dataLength.toInt()));
      }).whenComplete(() {
        if (need > 0) cache._release(need);
      });
      // A decode nobody reads (the window restarted) must not surface as an
      // unhandled error; a reader still sees the failure.
      final settled = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
      _running.add(settled);
      unawaited(settled.whenComplete(() => _running.remove(settled)));
      _ahead[op.index] = result;
    }
  }

  Future<Uint8List> _decodeOne(OpInfo op, Uint8List encoded) async {
    final expected = _totals[op.index]!;
    final what = '${partition.name}.img operation ${op.index}';
    final Uint8List decoded;
    try {
      decoded = await cache.decoder.decode(op, encoded, total: expected, blockSize: _blockSize, what: what);
    } on Object catch (error) {
      throw FlashException('$what: $error');
    }
    if (decoded.isNotEmpty && decoded.length != expected) {
      throw FlashException('$what has the wrong length.');
    }
    if (decoded.isEmpty && _decodes(op)) {
      throw FlashException('$what unexpectedly decoded no data.');
    }
    return decoded;
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
      final decoded = await _decode(span.op);
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
    _ahead.clear();
    // Wait for in-flight reads, so the archive is not closed under them;
    // fetched data is no longer decoded.
    await Future.wait(_running.toList());
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
