import 'dart:typed_data';

import 'package:flasher_web_core/flasher_web_core.dart';

import 'errors.dart';
import 'strict_http.dart';

/// A [ByteSource] for one GitHub release asset proxied by the approved edge.
///
/// The declared manifest size is authoritative: every 206 must name exactly
/// the requested bytes and the same total, and redirects or 200 responses are
/// refused by [StrictHttp].
final class EdgeRangeSource implements ByteSource {
  EdgeRangeSource({
    required this.http,
    required this.assetName,
    required this.length,
    required this.maxChunk,
  }) {
    if (assetName == '.' || assetName == '..') {
      throw const HostedInternalException(
        'bloat_asset_invalid',
        'The bloat manifest names an unsafe asset.',
      );
    }
  }

  final StrictHttp http;
  final String assetName;
  final int maxChunk;

  @override
  final int length;

  @override
  Future<Uint8List> read(int offset, int requested) async {
    checkReadRange(offset, requested, length);
    if (requested == 0) return Uint8List(0);
    if (requested > maxChunk) {
      throw const HostedInternalException(
        'bloat_chunk_too_large',
        'A bloat read exceeded the configured chunk size.',
      );
    }
    final uri = http.resolve(
      'api/bloat/${Uri.encodeComponent(assetName)}',
    );
    final StrictRangeResponse response;
    try {
      response = await http.range(
        uri,
        start: offset,
        end: offset + requested - 1,
      );
    } on HostedUpstreamStatus catch (error) {
      throw HostedException(
        'bloat_unavailable',
        'The bloat asset server returned HTTP ${error.status}.',
        status: 502,
      );
    }
    try {
      final ContentRange range;
      try {
        range = ContentRange.parse(response.header('content-range'));
      } on Object {
        throw const HostedException(
          'bloat_range_invalid',
          'The bloat asset server returned an invalid byte range.',
          status: 502,
        );
      }
      if (!range.isSatisfied ||
          range.start != offset ||
          range.end != offset + requested - 1 ||
          range.total != length) {
        throw const HostedException(
          'bloat_range_invalid',
          'The bloat asset server returned an invalid byte range.',
          status: 502,
        );
      }
      final declared = response.header('content-length');
      if (declared != null && int.tryParse(declared) != requested) {
        throw const HostedException(
          'bloat_range_invalid',
          'The bloat asset server returned a different body length.',
          status: 502,
        );
      }
      final bytes = Uint8List(requested);
      var written = 0;
      await for (final chunk in response.response) {
        if (written + chunk.length > requested) {
          throw const HostedException(
            'bloat_range_invalid',
            'The bloat asset server returned too many bytes.',
            status: 502,
          );
        }
        bytes.setRange(written, written + chunk.length, chunk);
        written += chunk.length;
      }
      if (written != requested) {
        throw const HostedException(
          'bloat_range_short',
          'The bloat asset server ended a byte range early.',
          status: 502,
        );
      }
      return bytes;
    } finally {
      await response.discard();
    }
  }
}
