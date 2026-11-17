// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../interop.dart';
import 'contract.dart';

UsbBackend createBackend() => BrowserUsbBackend.currentContext();

/// The browser implementation, also injectable with a synthetic WebUSB object.
/// It only reads device metadata; it never opens, claims, or transfers data.
final class BrowserUsbBackend implements UsbBackend {
  const BrowserUsbBackend({required this._usb, required this._secureContext});

  factory BrowserUsbBackend.currentContext() {
    final navigator = globalContext['navigator'];
    final value = navigator != null && navigator.isA<JSObject>()
        ? (navigator as JSObject)['usb']
        : null;
    final secure = globalContext['isSecureContext'];
    return BrowserUsbBackend(
      usb: value != null && value.isA<JSObject>()
          ? USB(value as JSObject)
          : null,
      secureContext:
          secure != null &&
          secure.isA<JSBoolean>() &&
          (secure as JSBoolean).toDart,
    );
  }

  final USB? _usb;
  final bool _secureContext;

  bool _hasFunction(String key) {
    final value = _usb?.getProperty<JSAny?>(key.toJS);
    return value != null && value.isA<JSFunction>();
  }

  @override
  UsbCapabilities get capabilities => UsbCapabilities(
    secureContext: _secureContext,
    canRequest: _hasFunction('requestDevice'),
    canList: _hasFunction('getDevices'),
  );

  void _require(String method) {
    if (!_secureContext) {
      throw const UsbException(
        UsbFailureKind.insecureContext,
        'WebUSB requires HTTPS or localhost.',
      );
    }
    if (!_hasFunction(method)) {
      throw const UsbException(
        UsbFailureKind.unsupported,
        'This execution context does not expose the requested WebUSB API.',
      );
    }
  }

  @override
  Future<UsbGrant> request({
    List<UsbFilter> filters = const [],
    List<UsbFilter> exclude = const [],
  }) {
    try {
      _require('requestDevice');
      final options = USBDeviceRequestOptions(
        filters: filters.map(_filter).toList().toJS,
        exclusionFilters: exclude.map(_filter).toList().toJS,
      );
      // Keep this in the calling click task: no async function, deferred
      // callback, or await before invoking requestDevice.
      return _settleRequest(_usb!.requestDevice(options));
    } on Object catch (error) {
      return Future.error(_failure(error));
    }
  }

  Future<UsbGrant> _settleRequest(JSPromise<USBDevice> promise) async {
    try {
      return _grant(await promise.toDart);
    } on Object catch (error) {
      throw _failure(error);
    }
  }

  @override
  Future<List<UsbGrant>> granted() {
    try {
      _require('getDevices');
      return _settleGranted(_usb!.getDevices());
    } on Object catch (error) {
      return Future.error(_failure(error, chooser: false));
    }
  }

  Future<List<UsbGrant>> _settleGranted(
    JSPromise<JSArray<USBDevice>> promise,
  ) async {
    try {
      return (await promise.toDart).toDart.map(_grant).toList(growable: false);
    } on Object catch (error) {
      throw _failure(error, chooser: false);
    }
  }
}

USBDeviceFilter _filter(UsbFilter filter) =>
    (<String, Object>{
          if (filter.vendorId != null) 'vendorId': filter.vendorId!,
          if (filter.productId != null) 'productId': filter.productId!,
          if (filter.classCode != null) 'classCode': filter.classCode!,
          if (filter.subclassCode != null) 'subclassCode': filter.subclassCode!,
          if (filter.protocolCode != null) 'protocolCode': filter.protocolCode!,
          if (filter.serialNumber != null) 'serialNumber': filter.serialNumber!,
        }.jsify()!
        as USBDeviceFilter);

UsbGrant _grant(USBDevice device) => UsbGrant(
  vendorId: device.vendorId,
  productId: device.productId,
  handle: device,
  serial: device.serialNumber,
  product: device.productName,
  manufacturer: device.manufacturerName,
);

String? _field(Object error, String key) {
  try {
    final value = error as JSAny;
    if (!value.isA<JSObject>()) return null;
    final field = (value as JSObject).getProperty<JSAny?>(key.toJS);
    return field != null && field.isA<JSString>()
        ? (field as JSString).toDart
        : null;
  } on Object {
    return null;
  }
}

UsbException _failure(Object error, {bool chooser = true}) {
  if (error is UsbException) return error;
  final name = _field(error, 'name');
  return UsbException(
    switch (name) {
      'NotFoundError' when chooser => UsbFailureKind.cancelled,
      'SecurityError' || 'NotAllowedError' => UsbFailureKind.permission,
      _ => UsbFailureKind.other,
    },
    _field(error, 'message') ?? '$error',
    name: name,
    stack: _field(error, 'stack'),
    cause: error,
  );
}
