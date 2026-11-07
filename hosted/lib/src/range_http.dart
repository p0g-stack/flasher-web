import 'dart:io';

/// One satisfiable byte range.
final class ByteRange {
  const ByteRange(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start + 1;
}

final class RangeNotSatisfiable implements Exception {
  const RangeNotSatisfiable();
}

/// Parses one RFC 9110 range. Multiple ranges are refused; a caller that
/// serves one range must not silently answer a multipart request.
ByteRange parseSingleRange(String header, int length) {
  final value = header.trim();
  if (!value.toLowerCase().startsWith('bytes=')) {
    throw const RangeNotSatisfiable();
  }
  final spec = value.substring(6).trim();
  if (spec.isEmpty || spec.contains(',')) {
    throw const RangeNotSatisfiable();
  }
  final dash = spec.indexOf('-');
  if (dash < 0) throw const RangeNotSatisfiable();
  final left = spec.substring(0, dash).trim();
  final right = spec.substring(dash + 1).trim();
  if (left.isEmpty) {
    final suffix = int.tryParse(right);
    if (suffix == null || suffix <= 0 || length <= 0) {
      throw const RangeNotSatisfiable();
    }
    final start = suffix >= length ? 0 : length - suffix;
    return ByteRange(start, length - 1);
  }
  final start = int.tryParse(left);
  if (start == null || start < 0 || start >= length) {
    throw const RangeNotSatisfiable();
  }
  if (right.isEmpty) return ByteRange(start, length - 1);
  final requestedEnd = int.tryParse(right);
  if (requestedEnd == null || requestedEnd < start) {
    throw const RangeNotSatisfiable();
  }
  final end = requestedEnd >= length ? length - 1 : requestedEnd;
  return ByteRange(start, end);
}

/// Strong comparison for `If-Range`; weak tags never match.
bool ifRangeMatches(String? header, String etag) {
  if (header == null) return true;
  final value = header.trim();
  if (value.isEmpty) return true;
  if (value.startsWith('W/') || value.startsWith('w/')) return false;
  return value == etag;
}

/// `If-None-Match` for one strong entity tag.
bool ifNoneMatch(String? header, String etag) {
  if (header == null) return false;
  return header.split(',').any((candidate) {
    final value = candidate.trim();
    return value == '*' || value == etag;
  });
}

/// A conservative RFC 5987 Content-Disposition for an operator-named file.
String contentDisposition(String filename) {
  final fallback = filename
      .replaceAll(RegExp(r'[^\x20-\x7e]'), '_')
      .replaceAll(RegExp(r'[\\"]'), '_');
  final encoded = Uri.encodeComponent(filename);
  return 'attachment; filename="$fallback"; filename*=UTF-8\'\'$encoded';
}

/// A server-side 416 response with the required unsatisfied range.
Future<void> sendRangeNotSatisfiable(HttpResponse response, int length) async {
  response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
  response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
  response.headers.contentType = ContentType.json;
  response.headers.set(HttpHeaders.cacheControlHeader, 'private, no-store');
  final body = '{"error":"The requested byte range is not satisfiable."}';
  response.contentLength = body.length;
  response.write(body);
  await response.close();
}
