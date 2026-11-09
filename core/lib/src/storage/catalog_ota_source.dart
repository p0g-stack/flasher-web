import '../catalog/catalog_client.dart';
import '../pipeline/ota_headers.dart';
import 'ota_cache.dart';
import 'storage.dart' show HttpRangeSource;

/// Resolves a catalog entry and opens its OTA through HTTP ranges.
///
/// This is the same path the build pipeline takes: `POST /api/resolve` for a
/// fresh signed URL, then ranged reads. On a browser host the reads go through
/// the same-origin `/api/ota` proxy, which adds OnePlus's CDN headers itself
/// and avoids CORS; a native host reads the direct link and sends
/// [otaRequestHeaders] with every request.
///
/// The virtual flash path streams through `HttpRangeSource` too, so the cache
/// and the one-shot path see identical bytes. A signed URL that expires
/// mid-download is re-resolved by [OtaCache.download], not here.
final class CatalogOtaSourceFactory implements OtaSourceFactory {
  CatalogOtaSourceFactory({
    required this.client,
    this.apiBase = '',
    this.proxyOta = false,
  });

  /// The same-origin catalog client that resolves signed links.
  final CatalogClient client;

  /// Origin or directory that `/api/ota` is relative to.
  final String apiBase;

  /// Route reads through `/api/ota`; true on a browser host.
  final bool proxyOta;

  @override
  Future<OtaRemoteSource> open(Map<String, dynamic> entry) async {
    final url = await client.resolveLink(entry);
    final source = await HttpRangeSource.open(_otaUri(url), headers: _headers);
    return OtaRemoteSource(source: source, etag: source.observedEtag);
  }

  /// The proxy adds the CDN headers; a direct read sends them itself.
  Map<String, String> get _headers =>
      proxyOta && apiBase.isNotEmpty ? const {} : otaRequestHeaders;

  Uri _otaUri(String url) => proxyOta && apiBase.isNotEmpty
      ? _proxiedOta(apiBase, url)
      : Uri.parse(url);

  static Uri _proxiedOta(String apiBase, String url) {
    // Natively there is no CORS proxy to route through; a direct link works.
    if (apiBase.isEmpty) return Uri.parse(url);
    final base = Uri.parse(apiBase.endsWith('/') ? apiBase : '$apiBase/');
    final uri = base.resolve('api/ota');
    return uri.replace(queryParameters: {'u': url});
  }
}
