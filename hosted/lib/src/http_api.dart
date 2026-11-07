import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'config.dart';
import 'errors.dart';
import 'job.dart';
import 'jobs.dart';
import 'range_http.dart';
import 'request.dart';
import 'util.dart';

/// The same-origin API behind the edge proxy. Authentication is the single
/// configured proxy secret; there is no alternate URL or upload route.
final class HostedApi {
  HostedApi({required this.service, required this.config});

  final HostedService service;
  final HostedConfig config;

  static const int maxRequestBytes = 16 * 1024;

  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set(HttpHeaders.cacheControlHeader, 'private, no-store');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    try {
      final supplied = request.headers.value('X-Hosted-Token');
      if (supplied == null ||
          !constantTimeEquals(supplied, config.token)) {
        await _json(
          request,
          response,
          HttpStatus.unauthorized,
          {'error': 'Unauthorized.'},
        );
        return;
      }
      if (request.uri.query.isNotEmpty) {
        await _error(
          request,
          response,
          const HostedException(
            'request_query_refused',
            'Query parameters are not supported.',
          ),
        );
        return;
      }
      final segments = request.uri.pathSegments;
      if (!_prefix(segments)) {
        await _notFound(request, response);
        return;
      }
      if (segments.length == 3) {
        if (request.method != 'POST') {
          await _method(request, response, 'POST');
          return;
        }
        await _submit(request, response);
        return;
      }
      if (segments.length == 4) {
        final id = segments[3];
        if (!urlSafeId.hasMatch(id)) {
          await _notFound(request, response);
          return;
        }
        await _job(request, response, id);
        return;
      }
      if (segments.length == 5) {
        final id = segments[3];
        if (!urlSafeId.hasMatch(id)) {
          await _notFound(request, response);
          return;
        }
        switch (segments[4]) {
          case 'artifact':
            await _artifact(request, response, id);
            break;
          case 'manifest':
            await _manifest(request, response, id);
            break;
          case 'lease':
            await _leaseAcquire(request, response, id);
            break;
          default:
            await _notFound(request, response);
        }
        return;
      }
      if (segments.length == 6 && segments[4] == 'lease') {
        final id = segments[3];
        final leaseId = segments[5];
        if (!urlSafeId.hasMatch(id) || !urlSafeId.hasMatch(leaseId)) {
          await _notFound(request, response);
          return;
        }
        await _leaseRelease(request, response, id, leaseId);
        return;
      }
      if (segments.length == 7 &&
          segments[4] == 'lease' &&
          segments[6] == 'renew') {
        final id = segments[3];
        final leaseId = segments[5];
        if (!urlSafeId.hasMatch(id) || !urlSafeId.hasMatch(leaseId)) {
          await _notFound(request, response);
          return;
        }
        await _leaseRenew(request, response, id, leaseId);
        return;
      }
      await _notFound(request, response);
    } on HostedException catch (error) {
      await _error(request, response, error);
    } on Object catch (error, stack) {
      stderr.writeln('hosted api error: $error\n$stack');
      try {
        await _json(
          request,
          response,
          HttpStatus.internalServerError,
          {'error': 'Internal server error.'},
        );
      } on Object {
        // The client may already be gone.
      }
    }
  }

  bool _prefix(List<String> segments) =>
      segments.length >= 3 &&
      segments[0] == 'api' &&
      segments[1] == 'hosted' &&
      segments[2] == 'jobs';

  Future<void> _submit(HttpRequest request, HttpResponse response) async {
    final type = request.headers.contentType;
    if (type == null || type.mimeType != 'application/json') {
      throw const HostedException(
        'content_type',
        'A JSON request body is required.',
        status: 415,
      );
    }
    final encoding = request.headers.value(HttpHeaders.contentEncodingHeader);
    if (encoding != null && encoding.toLowerCase() != 'identity') {
      throw const HostedException(
        'content_encoding',
        'Compressed request bodies are not supported.',
        status: 415,
      );
    }
    final body = await _body(request);
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(body));
    } on Object {
      throw const HostedException(
        'request_invalid',
        'The request body is not valid JSON.',
      );
    }
    final parsed = parseJobRequest(decoded);
    final result = await service.submit(parsed);
    await _json(
      request,
      response,
      result.statusCode,
      service.publicJob(result.job.id, hitOverride: result.reused ? true : null) ??
          result.job.publicJson(retention: config.retention),
    );
  }

  Future<void> _job(
    HttpRequest request,
    HttpResponse response,
    String id,
  ) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      await _method(request, response, 'GET, HEAD');
      return;
    }
    final job = service.job(id);
    if (job == null) {
      await _notFound(request, response);
      return;
    }
    final json = service.publicJob(id)!;
    await _json(request, response, HttpStatus.ok, json);
  }

  Future<void> _artifact(
    HttpRequest request,
    HttpResponse response,
    String id,
  ) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      await _method(request, response, 'GET, HEAD');
      return;
    }
    final job = service.job(id);
    if (job == null || job.state != HostedState.succeeded) {
      await _notFound(request, response);
      return;
    }
    final lease = await service.beginInternalOperation(
      id,
      ttl: config.internalLeaseTtl + config.artifactStreamTimeout,
    );
    try {
      final file = await service.artifact(id);
      final length = job.bytes!;
      final sha = job.sha256!;
      final etag = '"$sha"';
      final ifNone = request.headers.value(HttpHeaders.ifNoneMatchHeader);
      if (ifNoneMatch(ifNone, etag)) {
        response.statusCode = HttpStatus.notModified;
        response.headers.set(HttpHeaders.etagHeader, etag);
        response.contentLength = 0;
        await response.close();
        return;
      }
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
      final rangeAllowed = rangeHeader != null && ifRangeMatches(ifRange, etag);
      ByteRange? range;
      if (rangeAllowed) {
        try {
          range = parseSingleRange(rangeHeader, length);
        } on RangeNotSatisfiable {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
          response.headers.set(HttpHeaders.etagHeader, etag);
          response.headers.contentType = ContentType.json;
          final body = utf8.encode(
            '{"error":"The requested byte range is not satisfiable."}',
          );
          response.contentLength = request.method == 'HEAD' ? 0 : body.length;
          if (request.method != 'HEAD') response.add(body);
          await response.close();
          return;
        }
      }

      response.headers.set(HttpHeaders.contentTypeHeader, 'application/zip');
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.etagHeader, etag);
      response.headers.set(
        'content-disposition',
        contentDisposition(job.artifactName ?? 'flasher.zip'),
      );
      if (range == null) {
        response.statusCode = HttpStatus.ok;
        response.contentLength = length;
        if (request.method != 'HEAD') {
          await _stream(
            response,
            file.openRead(),
            lease.expiresAt,
          );
        }
      } else {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.end}/$length',
        );
        response.contentLength = range.length;
        if (request.method != 'HEAD') {
          await _stream(
            response,
            file.openRead(range.start, range.end + 1),
            lease.expiresAt,
          );
        }
      }
      await response.close();
    } finally {
      await service.endInternalOperation(lease);
    }
  }

  Future<void> _manifest(
    HttpRequest request,
    HttpResponse response,
    String id,
  ) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      await _method(request, response, 'GET, HEAD');
      return;
    }
    final job = service.job(id);
    if (job == null || job.state != HostedState.succeeded) {
      await _notFound(request, response);
      return;
    }
    final lease = await service.beginInternalOperation(id);
    try {
      final bytes = await service.manifest(id);
      final manifestSha = job.manifestSha256;
      if (manifestSha == null) {
        throw const HostedException(
          'manifest_missing',
          'The job has no retained manifest.',
          status: 404,
        );
      }
      final etag = '"$manifestSha"';
      if (ifNoneMatch(
        request.headers.value(HttpHeaders.ifNoneMatchHeader),
        etag,
      )) {
        response.statusCode = HttpStatus.notModified;
        response.headers.set(HttpHeaders.etagHeader, etag);
        response.contentLength = 0;
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType.json;
      response.headers.set(HttpHeaders.etagHeader, etag);
      response.contentLength = bytes.length;
      if (request.method != 'HEAD') response.add(bytes);
      await response.close();
    } finally {
      await service.endInternalOperation(lease);
    }
  }

  Future<void> _leaseAcquire(
    HttpRequest request,
    HttpResponse response,
    String id,
  ) async {
    if (request.method != 'POST') {
      await _method(request, response, 'POST');
      return;
    }
    await _body(request, allowEmpty: true);
    final lease = await service.acquireLease(id);
    await _json(
      request,
      response,
      HttpStatus.created,
      lease.toJson(
        config.leaseTtl.inSeconds,
        config.leaseMaxLifetime.inSeconds,
      ),
    );
  }

  Future<void> _leaseRenew(
    HttpRequest request,
    HttpResponse response,
    String id,
    String leaseId,
  ) async {
    if (request.method != 'POST') {
      await _method(request, response, 'POST');
      return;
    }
    await _body(request, allowEmpty: true);
    final lease = await service.renewLease(id, leaseId);
    await _json(
      request,
      response,
      HttpStatus.ok,
      lease.toJson(
        config.leaseTtl.inSeconds,
        config.leaseMaxLifetime.inSeconds,
      ),
    );
  }

  Future<void> _leaseRelease(
    HttpRequest request,
    HttpResponse response,
    String id,
    String leaseId,
  ) async {
    if (request.method != 'DELETE') {
      await _method(request, response, 'DELETE');
      return;
    }
    await _body(request, allowEmpty: true);
    service.releaseLease(id, leaseId);
    response.statusCode = HttpStatus.noContent;
    response.contentLength = 0;
    await response.close();
  }

  Future<void> _stream(
    HttpResponse response,
    Stream<List<int>> stream,
    DateTime leaseExpiresAt,
  ) async {
    final streamDeadline = DateTime.now().add(config.artifactStreamTimeout);
    final leaseDeadline = leaseExpiresAt.subtract(const Duration(seconds: 1));
    final deadline = streamDeadline.isBefore(leaseDeadline)
        ? streamDeadline
        : leaseDeadline;
    Duration remaining() {
      final left = deadline.difference(DateTime.now());
      return left.isNegative ? Duration.zero : left;
    }

    final iterator = StreamIterator<List<int>>(stream);
    try {
      while (await iterator.moveNext().timeout(remaining())) {
        if (remaining() == Duration.zero) {
          throw TimeoutException('artifact stream deadline');
        }
        response.add(iterator.current);
        await response.flush().timeout(remaining());
      }
    } on TimeoutException {
      await iterator.cancel();
      try {
        await response.close();
      } on Object {
        // The client is already gone.
      }
      throw const HostedException(
        'artifact_timeout',
        'The artifact transfer exceeded the configured time limit.',
        status: 504,
      );
    } on Object {
      await iterator.cancel();
      rethrow;
    }
  }

  Future<Uint8List> _body(
    HttpRequest request, {
    bool allowEmpty = false,
  }) async {
    final declared = request.contentLength;
    if (declared > maxRequestBytes) {
      throw const HostedException(
        'request_too_large',
        'The request body is too large.',
        status: 413,
      );
    }
    final chunks = <Uint8List>[];
    var length = 0;
    await for (final chunk in request) {
      length += chunk.length;
      if (length > maxRequestBytes) {
        throw const HostedException(
          'request_too_large',
          'The request body is too large.',
          status: 413,
        );
      }
      chunks.add(Uint8List.fromList(chunk));
    }
    final body = Uint8List(length);
    var offset = 0;
    for (final chunk in chunks) {
      body.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    if (body.isEmpty && !allowEmpty) {
      throw const HostedException(
        'request_empty',
        'The request body must not be empty.',
      );
    }
    if (body.isNotEmpty && allowEmpty) {
      throw const HostedException(
        'request_body_unexpected',
        'This request does not take a body.',
      );
    }
    return body;
  }

  Future<void> _json(
    HttpRequest request,
    HttpResponse response,
    int status,
    Object? value, {
    Map<String, String> headers = const {},
  }) async {
    final bytes = utf8.encode(jsonEncode(value));
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.headers.set(HttpHeaders.cacheControlHeader, 'private, no-store');
    for (final entry in headers.entries) {
      response.headers.set(entry.key, entry.value);
    }
    response.contentLength = request.method == 'HEAD' ? 0 : bytes.length;
    if (request.method != 'HEAD') response.add(bytes);
    await response.close();
  }

  Future<void> _error(
    HttpRequest request,
    HttpResponse response,
    HostedException error,
  ) async {
    await _json(
      request,
      response,
      error.status,
      {
        'error': error.message,
        'code': error.code,
      },
    );
  }

  Future<void> _notFound(HttpRequest request, HttpResponse response) async {
    await _json(
      request,
      response,
      HttpStatus.notFound,
      {'error': 'Not found.', 'code': 'not_found'},
    );
  }

  Future<void> _method(
    HttpRequest request,
    HttpResponse response,
    String allow,
  ) async {
    response.headers.set('allow', allow);
    await _json(
      request,
      response,
      HttpStatus.methodNotAllowed,
      {'error': 'Method not allowed.', 'code': 'method_not_allowed'},
    );
  }
}
