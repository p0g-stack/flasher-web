import 'package:flasher_web_hosted/src/range_http.dart';
import 'package:test/test.dart';

void main() {
  test('parses bounded, open and suffix ranges', () {
    expect(parseSingleRange('bytes=0-9', 100).length, 10);
    expect(parseSingleRange('bytes=90-', 100).start, 90);
    expect(parseSingleRange('bytes=90-', 100).end, 99);
    expect(parseSingleRange('bytes=-5', 100).start, 95);
    expect(parseSingleRange('bytes=95-1000', 100).end, 99);
  });

  test('refuses multiple, empty and unsatisfiable ranges', () {
    for (final header in [
      'bytes=0-1,4-5',
      'bytes=',
      'bytes=100-',
      'bytes=-0',
      'items=0-1',
      'bytes=5-4',
    ]) {
      expect(
        () => parseSingleRange(header, 100),
        throwsA(isA<RangeNotSatisfiable>()),
        reason: header,
      );
    }
  });

  test('If-Range uses strong comparison', () {
    expect(ifRangeMatches(null, '"abc"'), isTrue);
    expect(ifRangeMatches('"abc"', '"abc"'), isTrue);
    expect(ifRangeMatches('W/"abc"', '"abc"'), isFalse);
    expect(ifRangeMatches('"other"', '"abc"'), isFalse);
  });

  test('If-None-Match handles wildcard, exact and list values', () {
    expect(ifNoneMatch('*', '"abc"'), isTrue);
    expect(ifNoneMatch('"abc"', '"abc"'), isTrue);
    expect(ifNoneMatch('"x", "abc"', '"abc"'), isTrue);
    expect(ifNoneMatch('W/"abc"', '"abc"'), isFalse);
  });

  test('Content-Disposition is quoted and RFC 5987 encoded', () {
    final value = contentDisposition('Super Flasher 13" GLO.zip');
    expect(value, contains('filename="Super Flasher 13_ GLO.zip"'));
    expect(value, contains("filename*=UTF-8''"));
  });
}
