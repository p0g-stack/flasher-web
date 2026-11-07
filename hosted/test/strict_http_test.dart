import 'dart:convert';
import 'dart:io';

import 'package:flasher_web_hosted/src/errors.dart';
import 'package:flasher_web_hosted/src/strict_http.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late StrictHttp http;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/redirect':
          response.statusCode = HttpStatus.found;
          response.headers.set('location', '/ok');
          await response.close();
          break;
        case '/ok':
          response.write('ok');
          await response.close();
          break;
        case '/large':
          response.write('x' * 100);
          await response.close();
          break;
        case '/range':
          final length = 10;
          final raw = request.headers.value(HttpHeaders.rangeHeader) ?? '';
          final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(raw);
          if (match == null) {
            response.statusCode = HttpStatus.badRequest;
            await response.close();
          } else {
            final start = int.parse(match.group(1)!);
            final end = int.parse(match.group(2)!);
            response.statusCode = HttpStatus.partialContent;
            response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/$length',
            );
            response.headers.contentLength = end - start + 1;
            response.write('abcdefghij'.substring(start, end + 1));
            await response.close();
          }
        default:
          response.statusCode = HttpStatus.notFound;
          await response.close();
      }
    });
    http = StrictHttp(Uri.parse('http://127.0.0.1:${server.port}'));
  });

  tearDown(() async {
    http.close();
    await server.close(force: true);
  });

  test('refuses redirects instead of following them', () async {
    await expectLater(
      http.bytes('GET', http.resolve('redirect')),
      throwsA(
        isA<HostedInternalException>().having(
          (error) => error.code,
          'code',
          'upstream_redirect_refused',
        ),
      ),
    );
  });

  test('refuses another origin before sending', () async {
    await expectLater(
      http.bytes(
        'GET',
        Uri.parse('http://127.0.0.1:${server.port + 1}/ok'),
      ),
      throwsA(
        isA<HostedInternalException>().having(
          (error) => error.code,
          'code',
          'upstream_origin_refused',
        ),
      ),
    );
  });

  test('caps a response body', () async {
    await expectLater(
      http.bytes('GET', http.resolve('large'), maxBytes: 10),
      throwsA(isA<HostedInternalException>()),
    );
  });

  test('opens a validated 206 range', () async {
    final response = await http.range(
      http.resolve('range'),
      start: 2,
      end: 4,
    );
    expect(response.status, 206);
    expect(response.header('content-range'), 'bytes 2-4/10');
    final body = await response.response.fold<List<int>>(
      <int>[],
      (bytes, chunk) => bytes..addAll(chunk),
    );
    expect(utf8.decode(body), 'cde');
  });
}
