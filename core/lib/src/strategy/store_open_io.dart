import '../pipeline/errors.dart';
import '../storage/contracts.dart';
import '../storage/io/io_workspace.dart';

Workspace openPathStore(String path) => IoWorkspace.path(path);

Workspace openHandleStore(Object handle) =>
    throw const BuildException('This place cannot use a directory handle.');

Future<Workspace> openOpfsStore() async =>
    throw const BuildException('This place has no origin private file system.');
