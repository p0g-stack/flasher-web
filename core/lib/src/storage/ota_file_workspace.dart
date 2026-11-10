import 'contracts.dart';

/// Routes the engine's part/final archive to one user-picked file; small
/// sidecars live in [metadata], never beside a file without directory access.
final class OtaFileWorkspace implements Workspace {
  OtaFileWorkspace({
    required this.metadata,
    required this.openFile,
    required this.writeFile,
    required this.fileSize,
  });
  final Workspace metadata;
  final Future<ByteSource> Function() openFile;
  final Future<ByteSink> Function(bool keepExisting) writeFile;
  final Future<int> Function() fileSize;
  bool _archive(String path) => path.endsWith('.zip') || path.endsWith('.part');
  @override
  Future<ByteSink> create(String path) =>
      _archive(path) ? writeFile(false) : metadata.create(path);
  @override
  Future<ByteSink> update(String path) =>
      _archive(path) ? writeFile(true) : metadata.update(path);
  @override
  Future<ByteSource> open(String path) =>
      _archive(path) ? openFile() : metadata.open(path);
  @override
  Future<int> size(String path) =>
      _archive(path) ? fileSize() : metadata.size(path);
  @override
  Future<bool> exists(String path) async =>
      _archive(path) ? await fileSize() > 0 : metadata.exists(path);
  @override
  Future<List<String>> list(String dir, {bool recursive = false}) =>
      metadata.list(dir, recursive: recursive);
  @override
  Future<void> move(String from, String to) async {
    if (_archive(from) && _archive(to)) return; // Both name the same handle.
    await metadata.move(from, to);
  }

  @override
  Future<void> delete(String path) async {
    if (!_archive(path)) return metadata.delete(path);
    final sink = await writeFile(false);
    await sink.close();
  }
}
