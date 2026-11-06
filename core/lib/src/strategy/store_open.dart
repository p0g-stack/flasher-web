/// Opens the workspace behind a service `Store` request.
library;

import 'store_open_io.dart'
    if (dart.library.js_interop) 'store_open_web.dart'
    as platform;
import '../storage/contracts.dart';

Workspace openPathStore(String path) => platform.openPathStore(path);

Workspace openHandleStore(Object handle) => platform.openHandleStore(handle);

Future<Workspace> openOpfsStore() => platform.openOpfsStore();
