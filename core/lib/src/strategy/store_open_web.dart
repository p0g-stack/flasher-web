import 'dart:js_interop';

import '../pipeline/errors.dart';
import '../storage/contracts.dart';
import '../storage/web/handle_workspace.dart';

Workspace openPathStore(String path) =>
    throw const BuildException('This place cannot use a directory path.');

Workspace openHandleStore(Object handle) {
  try {
    return HandleWorkspace(handle as JSObject);
  } on TypeError {
    throw const BuildException('Choose an output folder.');
  }
}

Future<Workspace> openOpfsStore() => HandleWorkspace.opfs();
