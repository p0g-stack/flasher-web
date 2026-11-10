// SPDX-License-Identifier: LGPL-3.0-or-later

/// WebUSB's missing package:web bindings, following the WICG WebUSB IDL:
/// https://wicg.github.io/webusb/ (accessed 2026-11-09).
/// Enum-valued strings use their WebIDL spellings, e.g. 'in', 'out', 'bulk'.
/// These are raw APIs: the browser enforces validation and permissions.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

extension type USB(JSObject _) implements web.EventTarget, JSObject {
  external web.EventHandler get onconnect;
  external set onconnect(web.EventHandler value);
  external web.EventHandler get ondisconnect;
  external set ondisconnect(web.EventHandler value);
  external JSPromise<JSArray<USBDevice>> getDevices();
  external JSPromise<USBDevice> requestDevice(USBDeviceRequestOptions options);
}

extension type USBDeviceFilter._(JSObject _) implements JSObject {
  external factory USBDeviceFilter({
    int vendorId,
    int productId,
    int classCode,
    int subclassCode,
    int protocolCode,
    String serialNumber,
  });
  external int? get vendorId;
  external int? get productId;
  external int? get classCode;
  external int? get subclassCode;
  external int? get protocolCode;
  external String? get serialNumber;
}

extension type USBDeviceRequestOptions._(JSObject _) implements JSObject {
  external factory USBDeviceRequestOptions({
    required JSArray<USBDeviceFilter> filters,
    JSArray<USBDeviceFilter> exclusionFilters,
  });
  external JSArray<USBDeviceFilter> get filters;
  external JSArray<USBDeviceFilter>? get exclusionFilters;
}

extension type USBDevice(JSObject _) implements JSObject {
  external int get usbVersionMajor;
  external int get usbVersionMinor;
  external int get usbVersionSubminor;
  external int get deviceClass;
  external int get deviceSubclass;
  external int get deviceProtocol;
  external int get vendorId;
  external int get productId;
  external int get deviceVersionMajor;
  external int get deviceVersionMinor;
  external int get deviceVersionSubminor;
  external String? get manufacturerName;
  external String? get productName;
  external String? get serialNumber;
  external USBConfiguration? get configuration;
  external JSArray<USBConfiguration> get configurations;
  external bool get opened;
  external JSPromise<JSAny?> open();
  external JSPromise<JSAny?> close();
  external JSPromise<JSAny?> forget();
  external JSPromise<JSAny?> selectConfiguration(int configurationValue);
  external JSPromise<JSAny?> claimInterface(int interfaceNumber);
  external JSPromise<JSAny?> releaseInterface(int interfaceNumber);
  external JSPromise<JSAny?> selectAlternateInterface(
    int interfaceNumber,
    int alternateSetting,
  );
  external JSPromise<USBInTransferResult> controlTransferIn(
    USBControlTransferParameters setup,
    int length,
  );
  external JSPromise<USBOutTransferResult> controlTransferOut(
    USBControlTransferParameters setup, [
    JSObject data,
  ]);
  external JSPromise<JSAny?> clearHalt(String direction, int endpointNumber);
  external JSPromise<USBInTransferResult> transferIn(
    int endpointNumber,
    int length,
  );
  external JSPromise<USBOutTransferResult> transferOut(
    int endpointNumber,
    JSObject data,
  );
  external JSPromise<USBIsochronousInTransferResult> isochronousTransferIn(
    int endpointNumber,
    JSArray<JSNumber> packetLengths,
  );
  external JSPromise<USBIsochronousOutTransferResult> isochronousTransferOut(
    int endpointNumber,
    JSObject data,
    JSArray<JSNumber> packetLengths,
  );
  external JSPromise<JSAny?> reset();
}

extension type USBControlTransferParameters._(JSObject _) implements JSObject {
  external factory USBControlTransferParameters({
    required String requestType,
    required String recipient,
    required int request,
    required int value,
    required int index,
  });
  external String get requestType;
  external String get recipient;
  external int get request;
  external int get value;
  external int get index;
}

extension type USBConfiguration(JSObject _) implements JSObject {
  @JS('USBConfiguration')
  external factory USBConfiguration.fromDevice(
    USBDevice device,
    int configurationValue,
  );
  external int get configurationValue;
  external String? get configurationName;
  external JSArray<USBInterface> get interfaces;
}

extension type USBInterface(JSObject _) implements JSObject {
  @JS('USBInterface')
  external factory USBInterface.fromConfiguration(
    USBConfiguration configuration,
    int interfaceNumber,
  );
  external int get interfaceNumber;
  external USBAlternateInterface get alternate;
  external JSArray<USBAlternateInterface> get alternates;
  external bool get claimed;
}

extension type USBAlternateInterface(JSObject _) implements JSObject {
  @JS('USBAlternateInterface')
  external factory USBAlternateInterface.fromInterface(
    USBInterface deviceInterface,
    int alternateSetting,
  );
  external int get alternateSetting;
  external int get interfaceClass;
  external int get interfaceSubclass;
  external int get interfaceProtocol;
  external String? get interfaceName;
  external JSArray<USBEndpoint> get endpoints;
}

extension type USBEndpoint(JSObject _) implements JSObject {
  @JS('USBEndpoint')
  external factory USBEndpoint.fromAlternate(
    USBAlternateInterface alternate,
    int endpointNumber,
    String direction,
  );
  external int get endpointNumber;
  external String get direction;
  external String get type;
  external int get packetSize;
}

extension type USBInTransferResult(JSObject _) implements JSObject {
  @JS('USBInTransferResult')
  external factory USBInTransferResult.create(
    String status, [
    JSDataView? data,
  ]);
  external JSDataView? get data;
  external String get status;
}

extension type USBOutTransferResult(JSObject _) implements JSObject {
  @JS('USBOutTransferResult')
  external factory USBOutTransferResult.create(
    String status, [
    int bytesWritten,
  ]);
  external int get bytesWritten;
  external String get status;
}

extension type USBIsochronousInTransferPacket(JSObject _) implements JSObject {
  @JS('USBIsochronousInTransferPacket')
  external factory USBIsochronousInTransferPacket.create(
    String status, [
    JSDataView? data,
  ]);
  external JSDataView? get data;
  external String get status;
}

extension type USBIsochronousInTransferResult(JSObject _) implements JSObject {
  @JS('USBIsochronousInTransferResult')
  external factory USBIsochronousInTransferResult.create(
    JSArray<USBIsochronousInTransferPacket> packets, [
    JSDataView? data,
  ]);
  external JSDataView? get data;
  external JSArray<USBIsochronousInTransferPacket> get packets;
}

extension type USBIsochronousOutTransferPacket(JSObject _) implements JSObject {
  @JS('USBIsochronousOutTransferPacket')
  external factory USBIsochronousOutTransferPacket.create(
    String status, [
    int bytesWritten,
  ]);
  external int get bytesWritten;
  external String get status;
}

extension type USBIsochronousOutTransferResult(JSObject _) implements JSObject {
  @JS('USBIsochronousOutTransferResult')
  external factory USBIsochronousOutTransferResult.create(
    JSArray<USBIsochronousOutTransferPacket> packets,
  );
  external JSArray<USBIsochronousOutTransferPacket> get packets;
}

extension type USBConnectionEvent(JSObject _) implements web.Event, JSObject {
  @JS('USBConnectionEvent')
  external factory USBConnectionEvent.create(
    String type,
    USBConnectionEventInit eventInitDict,
  );
  external USBDevice get device;
}

extension type USBConnectionEventInit._(JSObject _)
    implements web.EventInit, JSObject {
  external factory USBConnectionEventInit({
    required USBDevice device,
    bool bubbles,
    bool cancelable,
    bool composed,
  });
  external USBDevice get device;
}
