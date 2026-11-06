/// HTTP `Range`/`Content-Range` checks shared by the IO and web sources.
///
/// A range source must see `206 Partial Content` with a `Content-Range` that
/// names exactly the requested bytes and the same total length on every read.
/// A server that ignores `Range`, shortens a range or changes the total is an
/// error: silently returning fewer bytes would corrupt an image.
library;

/// A malformed or unusable HTTP range response.
final class RangeException implements Exception {
  const RangeException(this.message);

  final String message;

  @override
  String toString() => 'RangeException: $message';
}

/// A parsed `Content-Range` header.
///
/// `bytes 10-19/100` has [start] 10, [end] 19 and [total] 100.
/// `bytes */0` (a 416 for an empty file) has no [start] and [end].
final class ContentRange {
  const ContentRange._(this.start, this.end, this.total);

  final int? start;
  final int? end;
  final int total;

  bool get isSatisfied => start != null;

  static final _satisfied = RegExp(
    r'^bytes\s+(\d+)-(\d+)/(\d+)$',
    caseSensitive: false,
  );
  static final _unsatisfied = RegExp(
    r'^bytes\s+\*/(\d+)$',
    caseSensitive: false,
  );

  /// Parses a `Content-Range` header, returning null when it is missing or
  /// malformed. A total of `*` is rejected: the source needs a stable length.
  static ContentRange? tryParse(String? header) {
    if (header == null) return null;
    final value = header.trim();
    final satisfied = _satisfied.firstMatch(value);
    if (satisfied != null) {
      final start = int.tryParse(satisfied.group(1)!);
      final end = int.tryParse(satisfied.group(2)!);
      final total = int.tryParse(satisfied.group(3)!);
      if (start == null || end == null || total == null) return null;
      if (start < 0 || end < start || total <= end) return null;
      return ContentRange._(start, end, total);
    }
    final unsatisfied = _unsatisfied.firstMatch(value);
    if (unsatisfied != null) {
      final total = int.tryParse(unsatisfied.group(1)!);
      if (total == null) return null;
      return ContentRange._(null, null, total);
    }
    return null;
  }

  /// Like [tryParse], but throws [RangeException] when the header is absent or
  /// malformed.
  static ContentRange parse(String? header) {
    final parsed = tryParse(header);
    if (parsed == null) {
      throw RangeException('invalid Content-Range: ${header ?? 'missing'}');
    }
    return parsed;
  }
}

/// Validates a `206` response for the exact requested range.
void validateRangeResponse({
  required int status,
  required String? contentRange,
  required int? contentLength,
  required int offset,
  required int length,
  required int expectedTotal,
}) {
  if (status != 206) {
    throw RangeException('expected 206 Partial Content, got $status');
  }
  final range = ContentRange.parse(contentRange);
  if (!range.isSatisfied) {
    throw RangeException('expected a satisfied range, got $contentRange');
  }
  if (range.start != offset || range.end != offset + length - 1) {
    throw RangeException(
      'server returned bytes ${range.start}-${range.end}, '
      'wanted $offset-${offset + length - 1}',
    );
  }
  if (range.total != expectedTotal) {
    throw RangeException(
      'remote length changed from $expectedTotal to ${range.total}',
    );
  }
  if (contentLength != null && contentLength >= 0 && contentLength != length) {
    throw RangeException('Content-Length is $contentLength, wanted $length');
  }
}

/// Reads the total from a `416` response's `Content-Range: bytes */N`.
int unsatisfiedTotal(String? contentRange) {
  final range = ContentRange.tryParse(contentRange);
  if (range == null || range.isSatisfied) {
    throw RangeException('invalid unsatisfied Content-Range: $contentRange');
  }
  return range.total;
}
