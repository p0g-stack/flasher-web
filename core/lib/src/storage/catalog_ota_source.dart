import 'block_ota_source.dart';
import 'ota_cache.dart';

/// The one catalog OTA reader on browsers and native/CLI hosts.
/// No signed URL or whole-file browser copy participates in catalog reads.
final class CatalogOtaSourceFactory implements OtaSourceFactory {
  CatalogOtaSourceFactory({this.apiBase = '', this.bucketBase});

  final String apiBase;
  final String? bucketBase;

  @override
  Future<OtaRemoteSource> open(Map<String, dynamic> entry) async {
    final id = entry['id'];
    if (id is! String) throw ArgumentError('A catalog release id is required.');
    final size = entry['size'];
    final source = await BlockOtaSource.open(
      id: id,
      apiBase: apiBase,
      bucketBase: bucketBase,
      expectedLength: size is int && size > 0 ? size : null,
    );
    return OtaRemoteSource(source: source, etag: source.etag);
  }
}
