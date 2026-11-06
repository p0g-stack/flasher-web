import 'platform_bridge.dart';

/// Non-web builds have no page bridge.
PlatformBridge createBridge() => const UnsupportedPlatformBridge();
