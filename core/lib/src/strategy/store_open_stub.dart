import '../pipeline/errors.dart';
import '../storage/contracts.dart';

Workspace openPathStore(String path) =>
    throw const BuildException('This place cannot use a directory path.');

Workspace openHandleStore(Object handle) =>
    throw const BuildException('This place cannot use a directory handle.');

Future<Workspace> openOpfsStore() async =>
    throw const BuildException('This place has no origin private file system.');
