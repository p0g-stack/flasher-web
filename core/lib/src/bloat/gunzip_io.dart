import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'gunzip.dart';

Gunzip createGunzip() => _IoGunzip();

final class _IoGunzip implements Gunzip {
  _IoGunzip() {
    _decoder = GZipCodec().decoder.startChunkedConversion(_out);
  }

  late final ByteConversionSink _decoder;
  final _CollectingSink _out = _CollectingSink();

  @override
  List<int> push(List<int> bytes) {
    _decoder.add(bytes);
    return _out.take();
  }

  @override
  List<int> finish() {
    _decoder.close();
    return _out.take();
  }
}

/// Collects decoded chunks until the caller takes them.
final class _CollectingSink implements Sink<List<int>> {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> data) => _bytes.add(data);

  @override
  void close() {}

  List<int> take() => _bytes.takeBytes();
}
