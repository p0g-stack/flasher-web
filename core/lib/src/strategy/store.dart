/// Where a job reads and writes: a picked directory, OPFS, or a host path.
///
/// The service receives a `Store` map; its kind selects the strategy and the
/// strategy's facts decide whether this place can run it. Every run logs the
/// strategy, the place and its facts.
library;

import '../facts/facts.dart';
import '../pipeline/errors.dart';
import '../storage/contracts.dart';
import 'objective.dart';
import 'strategy.dart';
import 'store_open.dart';

/// A validated `Store` request.
final class StoreSpec {
  const StoreSpec._({required this.kind, this.path, this.handle});

  /// Parses `{"kind": "directory"|"opfs"|"path", ...}`.
  factory StoreSpec.fromMap(Object? value, {String field = 'store'}) {
    if (value is! Map) {
      throw BuildException('Missing $field.');
    }
    final kind = value['kind'];
    switch (kind) {
      case 'directory':
        final handle = value['handle'];
        if (handle == null) throw BuildException('Choose a folder for $field.');
        return StoreSpec._(kind: 'directory', handle: handle);
      case 'opfs':
        return const StoreSpec._(kind: 'opfs');
      case 'path':
        final path = value['path'];
        if (path is! String || path.isEmpty) {
          throw BuildException('Missing path for $field.');
        }
        return StoreSpec._(kind: 'path', path: path);
      default:
        throw BuildException('Unknown $field kind: $kind.');
    }
  }

  final String kind;
  final String? path;
  final Object? handle;

  Map<String, Object?> toMap() => {
    'kind': kind,
    if (path != null) 'path': path,
  };
}

/// Opens [spec] in [place] with the strategy its kind names.
Future<Workspace> openStoreWithFacts(StoreSpec spec, PlaceInfo place) {
  final objective = Objective<StoreSpec, Workspace>(
    'store.${spec.kind}',
    switch (spec.kind) {
      'directory' => const [HandleStore()],
      'opfs' => const [OpfsStore()],
      'path' => const [PathStore()],
      _ => const <Strategy<StoreSpec, Workspace>>[],
    },
  );
  return objective.run(spec, place);
}

final class HandleStore extends ReadStrategy<StoreSpec, Workspace> {
  const HandleStore();

  @override
  String get name => 'handle_directory';

  @override
  Set<String> get requires => const {Fact.fsHandle};

  @override
  Future<Workspace> run(StoreSpec input, PlaceInfo place) async =>
      openHandleStore(input.handle!);
}

final class OpfsStore extends ReadStrategy<StoreSpec, Workspace> {
  const OpfsStore();

  @override
  String get name => 'opfs';

  @override
  Set<String> get requires => const {Fact.fsOpfs};

  @override
  Future<Workspace> run(StoreSpec input, PlaceInfo place) => openOpfsStore();
}

final class PathStore extends ReadStrategy<StoreSpec, Workspace> {
  const PathStore();

  @override
  String get name => 'path';

  @override
  Set<String> get requires => const {Fact.fsPath};

  @override
  Future<Workspace> run(StoreSpec input, PlaceInfo place) async =>
      openPathStore(input.path!);
}
