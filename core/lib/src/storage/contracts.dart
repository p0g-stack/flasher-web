import 'dart:typed_data';

/// Read-only random access to a byte range.
///
/// [length] is the number of bytes in the source and does not change while the
/// source is open. [read] returns exactly the requested number of bytes or
/// throws: a short read is an error, not a smaller result.
abstract interface class ByteSource {
  int get length;

  Future<Uint8List> read(int offset, int length);
}

/// Positional writes to a byte range.
///
/// Writes do not move a shared cursor: [write] puts [bytes] at [offset] and
/// leaves every other byte alone. Extending past the old end reads back as
/// zero bytes. [truncate] also extends with zero bytes.
abstract interface class ByteSink {
  Future<void> write(Uint8List bytes, int offset);

  Future<void> truncate(int length);

  Future<void> close();
}

/// A directory tree with `/`-separated, relative paths.
///
/// Every path is relative to the workspace root. Absolute paths and `..`
/// components are rejected. [list] returns files only, relative to the
/// workspace root, sorted.
abstract interface class Workspace {
  /// Creates [path] and its parents, replacing an existing file.
  Future<ByteSink> create(String path);

  /// Opens [path] for positional writes, keeping the bytes it already has.
  ///
  /// A missing file is created with its parents, like [create]. Unlike
  /// [create], an existing file is not truncated, so a download that was
  /// interrupted resumes at its recorded offset instead of starting over.
  Future<ByteSink> update(String path);

  Future<ByteSource> open(String path);

  Future<bool> exists(String path);

  Future<int> size(String path);

  Future<List<String>> list(String dir, {bool recursive = false});

  /// Moves [from] to [to]. An existing destination file is replaced; a file
  /// move is one rename where the platform allows it.
  Future<void> move(String from, String to);

  /// Deletes a file or a directory recursively. A missing path is a no-op.
  Future<void> delete(String path);
}

/// Releases a source's handle when its implementation has one.
///
/// [ByteSource] has no `close`: a browser `Blob` has nothing to release, while
/// a file or an HTTP client does. Sources that own a handle expose `close()`;
/// this calls it when present and ignores its absence.
Future<void> closeByteSource(ByteSource source) async {
  final dynamic closable = source;
  try {
    await closable.close();
  } on NoSuchMethodError {
    // Nothing to release.
  }
}

/// Checks that the half-open range starting at [offset] with [length] bytes
/// lies inside a source of [sourceLength] bytes.
void checkReadRange(int offset, int length, int sourceLength) {
  if (offset < 0) {
    throw RangeError.range(offset, 0, sourceLength, 'offset');
  }
  if (length < 0) {
    throw RangeError.value(length, 'length', 'must not be negative');
  }
  if (offset > sourceLength || length > sourceLength - offset) {
    throw RangeError.range(
      offset + length,
      offset,
      sourceLength,
      'offset + length',
    );
  }
}

/// Checks an offset for a positional write. The write itself may extend the
/// file.
void checkWriteOffset(int offset) {
  if (offset < 0) {
    throw RangeError.value(offset, 'offset', 'must not be negative');
  }
}

/// Checks a length passed to [ByteSink.truncate].
void checkTruncateLength(int length) {
  if (length < 0) {
    throw RangeError.value(length, 'length', 'must not be negative');
  }
}
