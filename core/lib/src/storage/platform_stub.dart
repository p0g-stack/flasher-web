/// The storage API when neither `dart:io` nor `dart:js_interop` is available.
///
/// This is the analyzer's default branch and the fallback for an unsupported
/// target. The classes keep the public names and signatures of the VM and web
/// implementations so callers type-check; every operation throws
/// [UnsupportedError]. At runtime a real target selects `platform_io.dart` or
/// `platform_web.dart` instead.
library;

import 'dart:typed_data';

import 'contracts.dart';

Never _unsupported() =>
    throw UnsupportedError('storage needs dart:io or dart:js_interop');

final class IoWorkspace implements Workspace {
  IoWorkspace(Object root) : _root = root;

  factory IoWorkspace.path(String path) => IoWorkspace(path);

  final Object _root;

  dynamic get root => _root;

  @override
  Future<ByteSink> create(String path) async => _unsupported();

  @override
  Future<ByteSink> update(String path) async => _unsupported();

  @override
  Future<ByteSource> open(String path) async => _unsupported();

  @override
  Future<bool> exists(String path) async => _unsupported();

  @override
  Future<int> size(String path) async => _unsupported();

  @override
  Future<List<String>> list(String dir, {bool recursive = false}) async =>
      _unsupported();

  @override
  Future<void> move(String from, String to) async => _unsupported();

  @override
  Future<void> delete(String path) async => _unsupported();
}

final class FileSource implements ByteSource {
  FileSource(Object file);

  static Future<FileSource> open(Object file) async => FileSource(file);

  @override
  int get length => _unsupported();

  @override
  Future<Uint8List> read(int offset, int length) async => _unsupported();

  Future<void> close() async => _unsupported();
}

final class FileSink implements ByteSink {
  FileSink._();

  static Future<FileSink> open(Object file) async => FileSink._();

  @override
  Future<void> write(Uint8List bytes, int offset) async => _unsupported();

  @override
  Future<void> truncate(int length) async => _unsupported();

  @override
  Future<void> close() async => _unsupported();
}

final class BlobSource implements ByteSource {
  BlobSource(Object blob);

  @override
  int get length => _unsupported();

  @override
  Future<Uint8List> read(int offset, int length) async => _unsupported();
}

final class HandleWorkspace implements Workspace {
  HandleWorkspace(Object directoryHandle);

  static Future<HandleWorkspace> opfs() async => _unsupported();

  @override
  Future<ByteSink> create(String path) async => _unsupported();

  @override
  Future<ByteSink> update(String path) async => _unsupported();

  @override
  Future<ByteSource> open(String path) async => _unsupported();

  @override
  Future<bool> exists(String path) async => _unsupported();

  @override
  Future<int> size(String path) async => _unsupported();

  @override
  Future<List<String>> list(String dir, {bool recursive = false}) async =>
      _unsupported();

  @override
  Future<void> move(String from, String to) async => _unsupported();

  @override
  Future<void> delete(String path) async => _unsupported();
}

final class HttpRangeSource implements ByteSource {
  HttpRangeSource._();

  static Future<HttpRangeSource> open(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async => HttpRangeSource._();

  /// The strong ETag the probe observed; this branch never probes.
  String? get observedEtag => null;

  @override
  int get length => _unsupported();

  @override
  Future<Uint8List> read(int offset, int length) async => _unsupported();

  Future<void> close() async => _unsupported();
}
