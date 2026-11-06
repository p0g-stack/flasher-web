import '../storage/contracts.dart';
import 'errors.dart';

/// No file access in this place.
Future<ByteSource> openLocalOta(Object file) async {
  throw const BuildException('This place cannot read a local OTA file.');
}
