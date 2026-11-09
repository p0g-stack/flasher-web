export 'cpu_count_stub.dart'
    if (dart.library.io) 'cpu_count_io.dart'
    if (dart.library.js_interop) 'cpu_count_web.dart';
