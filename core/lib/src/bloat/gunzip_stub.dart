import 'gunzip.dart';

Gunzip createGunzip() => throw UnsupportedError(
  'No gzip decoder in this place: the app injects the Rust decoder, '
  'the CLI uses dart:io.',
);
