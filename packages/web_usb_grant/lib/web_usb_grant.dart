// SPDX-License-Identifier: LGPL-3.0-or-later

import 'src/backend_stub.dart'
    if (dart.library.js_interop) 'src/backend_web.dart'
    as platform;
import 'src/contract.dart';

export 'src/contract.dart';

/// Page-side WebUSB permission and granted-device discovery, without Flutter.
final class WebUsb {
  WebUsb({UsbBackend? backend})
    : _backend = backend ?? platform.createBackend();

  final UsbBackend _backend;

  UsbCapabilities get capabilities => _backend.capabilities;
  bool get isSupported => capabilities.isSupported;

  /// Call directly from a user gesture, before any await. The browser chooser
  /// is invoked before this method returns its Future. Cancellation throws
  /// UsbException(kind: UsbFailureKind.cancelled), not a permission failure.
  /// [exclude] maps to WebUSB's exclusionFilters (not an additional allowlist).
  Future<UsbGrant> request({
    List<UsbFilter> filters = const [],
    List<UsbFilter> exclude = const [],
  }) => _backend.request(filters: filters, exclude: exclude);

  /// Lists existing grants without showing a chooser or opening any device.
  /// Workers can list grants but cannot invoke the chooser.
  Future<List<UsbGrant>> granted() => _backend.granted();
}
