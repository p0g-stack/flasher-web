import 'bridge_stub.dart'
    if (dart.library.js_interop) 'bridge_web.dart'
    as platform;
import 'platform_bridge.dart';

/// Creates the page bridge for the target this build was compiled for.
PlatformBridge createPlatformBridge() => platform.createBridge();
