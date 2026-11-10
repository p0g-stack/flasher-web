// SPDX-License-Identifier: LGPL-3.0-or-later

/// Facts about this execution context, not a browser-name guess.
final class UsbCapabilities {
  const UsbCapabilities({
    required this.secureContext,
    required this.canRequest,
    required this.canList,
  });

  final bool secureContext;
  final bool canRequest;
  final bool canList;

  bool get isSupported => secureContext && canRequest && canList;
}

/// A WebUSB device filter. Fields have the meanings and constraints of
/// https://wicg.github.io/webusb/#dictdef-usbdevicefilter.
/// The browser validates combinations and numeric ranges.
final class UsbFilter {
  const UsbFilter({
    this.vendorId,
    this.productId,
    this.classCode,
    this.subclassCode,
    this.protocolCode,
    this.serialNumber,
  });

  final int? vendorId;
  final int? productId;
  final int? classCode;
  final int? subclassCode;
  final int? protocolCode;
  final String? serialNumber;
}

/// A granted device. Reading a grant never opens or claims the device.
final class UsbGrant {
  const UsbGrant({
    required this.vendorId,
    required this.productId,
    required this.handle,
    this.serial,
    this.product,
    this.manufacturer,
  });

  final int vendorId;
  final int productId;
  final String? serial;
  final String? product;
  final String? manufacturer;

  /// The raw browser USBDevice; cast to USBDevice from interop.dart on web.
  /// Do not send this handle to a worker. Re-enumerate grants there instead.
  final Object handle;

  /// Opt-in policy for clients that must reopen the same serial in a worker.
  /// Devices without serial numbers remain valid grants for other consumers.
  String requireSerial() {
    final value = serial?.trim();
    if (value == null || value.isEmpty) {
      throw const UsbException(
        UsbFailureKind.noSerial,
        'The granted USB device does not expose a serial number.',
      );
    }
    return value;
  }
}

enum UsbFailureKind {
  cancelled,
  permission,
  insecureContext,
  unsupported,
  noSerial,
  other,
}

/// Browser failures retain the original DOMException fields without replacing
/// its message with app-specific guidance. Probe failures have no DOM name.
final class UsbException implements Exception {
  const UsbException(
    this.kind,
    this.message, {
    this.name,
    this.stack,
    this.cause,
  });

  final UsbFailureKind kind;
  final String message;
  final String? name;
  final String? stack;
  final Object? cause;

  @override
  String toString() => name == null ? message : '$name: $message';
}

/// Inject a backend into WebUsb for deterministic application tests.
/// Implementations must invoke the chooser synchronously in [request], before
/// returning its Future. No scheduling or awaiting may precede that invocation.
abstract interface class UsbBackend {
  UsbCapabilities get capabilities;

  Future<UsbGrant> request({
    List<UsbFilter> filters = const [],
    List<UsbFilter> exclude = const [],
  });

  Future<List<UsbGrant>> granted();
}
