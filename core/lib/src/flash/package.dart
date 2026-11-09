/// Bounded, read-only access to an image the flash plan reads.
///
/// The OTA-direct package (`virtual.dart`) is the only implementation that
/// ships: it exposes payload partitions and verified bloat images without
/// staging them in a workspace.
library;

import 'dart:typed_data';

import 'package_index.dart';

/// A random-access image source. [read] is for small headers; images are
/// streamed through [cursor].
abstract interface class FlashSource {
  int get length;

  Future<Uint8List> read(int offset, int length);

  /// Sequential bytes, each chunk at most [chunkSize].
  Stream<Uint8List> stream({int chunkSize = 1 << 20});

  /// A forward-only cursor over the whole image. Offsets must not decrease.
  Future<FlashCursor> cursor();

  Future<void> close();
}

/// Forward-only bounded reads. A sparse plan revisits data in file order.
abstract interface class FlashCursor {
  Future<Uint8List> readExact(int length);

  /// Advances to [offset]; [offset] must be at or after the current position.
  Future<void> skipTo(int offset);

  Future<void> close();
}

/// A package whose entries are known without opening every image.
///
/// Tests provide their own in-memory implementations.
abstract interface class FlashPackage {
  PackageIndex get index;

  Map<String, Object?> get buildJson;

  String get format;

  Future<int> size(String path);

  Future<FlashSource> open(String path);

  /// A stable description of the package's entries and metadata. A
  /// confirmation token binds this snapshot so a changed package is refused.
  Future<Map<String, Object?>> snapshot();
}
