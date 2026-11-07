import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../storage/range.dart';
import '../storage/storage.dart' show ByteSource;
import '../storage/web/http_range_source.dart';
import '../storage/web/interop.dart';
import 'hosted.dart';
import 'model.dart';

/// Hosted jobs are fetched from this origin only. The path is fixed; no
/// caller-supplied URL is accepted.
Uri hostedJobUri(String jobId, [String suffix = '']) =>
    Uri(path: '/api/hosted/jobs/$jobId$suffix');

HostedTransport createHostedTransport() => WebHostedTransport();

/// Same-origin `fetch` implementation of the hosted contract.
final class WebHostedTransport implements HostedTransport {
  @override
  Future<HostedJobInfo> readJob(HostedArtifact artifact) async {
    final response = await _send(hostedJobUri(artifact.jobId));
    final bytes = await _body(response, maxBytes: 1 << 20, what: 'job metadata');
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (error) {
      throw FlashException('The hosted job metadata is not JSON: $error');
    }
    if (decoded is! Map) {
      throw const FlashException('The hosted job metadata is not an object.');
    }
    return parseHostedJobInfo(Map<String, Object?>.from(decoded), artifact);
  }

  @override
  Future<Uint8List> readManifest(HostedArtifact artifact) async {
    final response = await _send(hostedJobUri(artifact.jobId, '/manifest'));
    return _body(response, maxBytes: 1 << 20, what: 'build.json');
  }

  @override
  Future<ByteSource> openArtifact(HostedArtifact artifact) {
    return HttpRangeSource.open(
      hostedJobUri(artifact.jobId, '/artifact'),
      expectedLength: artifact.bytes,
      expectedEtag: artifact.strongEtag,
    );
  }

  @override
  Future<HostedLease> acquireLease(HostedArtifact artifact) async {
    final response = await _send(
      hostedJobUri(artifact.jobId, '/lease'),
      method: 'POST',
    );
    final bytes = await _body(
      response,
      maxBytes: 1 << 16,
      what: 'lease',
      ok: const {200, 201},
    );
    return _WebLease.open(
      artifact,
      _decodeLease(bytes),
    );
  }

  Future<web.Response> _send(
    Uri uri, {
    String method = 'GET',
    bool acceptJson = false,
  }) {
    final headers = web.Headers();
    if (acceptJson) headers.set('accept', 'application/json');
    return webFetch(
      uri.toString().toJS,
      web.RequestInit(method: method, headers: headers),
    ).toDart;
  }

  Future<Uint8List> _body(
    web.Response response, {
    required int maxBytes,
    required String what,
    Set<int> ok = const {200},
  }) async {
    final contentLength = response.headers.get('content-length');
    if (contentLength != null) {
      final declared = int.tryParse(contentLength);
      if (declared != null && declared > maxBytes) {
        throw FlashException('The hosted $what is too large.');
      }
    }
    if (!ok.contains(response.status)) {
      final actual = response.status;
      await _cancel(response);
      throw FlashException(
        'The hosted $what returned HTTP $actual. Load the job again.',
      );
    }
    final bytes = (await response.arrayBuffer().toDart).toDart.asUint8List();
    if (bytes.length > maxBytes) {
      throw FlashException('The hosted $what is too large.');
    }
    return bytes;
  }

  static Future<void> _cancel(web.Response response) async {
    try {
      final body = response.body;
      if (body != null) await body.cancel().toDart;
    } on Object {
      // The body was already consumed or cannot be cancelled.
    }
  }
}

/// A lease obtained from `POST .../lease`.
final class _WebLease implements HostedLease {
  _WebLease._(this._artifact, this.leaseId, this.expiresAt);

  factory _WebLease.open(HostedArtifact artifact, _LeaseReply reply) {
    if (reply.expiresAt.isBefore(DateTime.now().toUtc())) {
      throw const FlashException('The hosted service returned an expired lease.');
    }
    return _WebLease._(artifact, reply.leaseId, reply.expiresAt);
  }

  final HostedArtifact _artifact;
  final String leaseId;

  @override
  DateTime expiresAt;

  @override
  Future<DateTime> renew() async {
    final response = await createWebSender(
      hostedJobUri(
        _artifact.jobId,
        '/lease/${Uri.encodeComponent(leaseId)}/renew',
      ),
      method: 'POST',
    );
    final bytes = await _leaseBody(response, 'lease renewal');
    final reply = _decodeLease(bytes);
    if (reply.leaseId != leaseId) {
      throw const FlashException('The hosted lease identity changed on renew.');
    }
    expiresAt = reply.expiresAt;
    return expiresAt;
  }

  @override
  Future<void> release() async {
    final response = await createWebSender(
      hostedJobUri(
        _artifact.jobId,
        '/lease/${Uri.encodeComponent(leaseId)}',
      ),
      method: 'DELETE',
    );
    try {
      if (response.status == 200 ||
          response.status == 202 ||
          response.status == 204 ||
          response.status == 404) {
        return;
      }
      await WebHostedTransport._cancel(response);
      throw FlashException(
        'Releasing the hosted lease returned HTTP ${response.status}.',
      );
    } on FlashException {
      rethrow;
    } on Object {
      // A release is best effort at close; the server expires the lease.
    }
  }

  static Future<web.Response> createWebSender(
    Uri uri, {
    String method = 'GET',
  }) {
    return webFetch(
      uri.toString().toJS,
      web.RequestInit(method: method),
    ).toDart;
  }

  static Future<Uint8List> _leaseBody(
    web.Response response,
    String what,
  ) async {
    if (response.status != 200) {
      final actual = response.status;
      await WebHostedTransport._cancel(response);
      throw FlashException('The hosted $what returned HTTP $actual.');
    }
    final bytes = (await response.arrayBuffer().toDart).toDart.asUint8List();
    if (bytes.length > 1 << 16) {
      throw FlashException('The hosted $what is too large.');
    }
    return bytes;
  }
}

final class _LeaseReply {
  const _LeaseReply(this.leaseId, this.expiresAt);
  final String leaseId;
  final DateTime expiresAt;
}

_LeaseReply _decodeLease(Uint8List bytes) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException catch (error) {
    throw FlashException('The hosted lease reply is not JSON: $error');
  }
  if (decoded is! Map) {
    throw const FlashException('The hosted lease reply is not an object.');
  }
  final leaseId = decoded['leaseId'];
  if (leaseId is! String || leaseId.isEmpty) {
    throw const FlashException('The hosted lease reply has no leaseId.');
  }
  final expiry = decoded['expiresAt'];
  DateTime? expiresAt;
  if (expiry is String) expiresAt = DateTime.tryParse(expiry)?.toUtc();
  final expiresIn = decoded['expiresIn'];
  if (expiresAt == null && expiresIn is num && expiresIn > 0) {
    expiresAt = DateTime.now().toUtc().add(
      Duration(milliseconds: (expiresIn * 1000).round()),
    );
  }
  if (expiresAt == null) {
    throw const FlashException(
      'The hosted lease reply has no usable expiry.',
    );
  }
  return _LeaseReply(leaseId, expiresAt);
}

/// Range errors and lease refusals keep their message when the service
/// reports them back to the page.
String describeHostedError(Object error) {
  if (error is RangeException) return error.message;
  return '$error';
}
