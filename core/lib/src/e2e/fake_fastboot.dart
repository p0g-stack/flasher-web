/// The end-to-end test's recording fastboot device.
///
/// Compiled in only when the build defines `FLASHER_FAKE_USB=true`: the
/// service's default transport factory checks that define with a constant
/// `bool.fromEnvironment` branch, so a production build drops this library
/// and its marker string entirely.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';

import '../flash/model.dart' show FlashMode;
import 'fake_channel.dart';

/// The fake phone's serial. It is not a real device serial.
const String fakeFastbootSerial = 'FAKE-E2E-0001';

/// A unique string the production bundle must not contain.
const String fakeFastbootMarker = 'FAKE-FASTBOOT-E2E-MARKER-8f3a2c';

/// The page's control/observation channel for the fake device.
const String fakeFastbootChannelName = 'flasher-e2e';

final _FakeDevice _device = _FakeDevice();
var _channelInstalled = false;

/// The recording fake transport, shared by every service call in this place.
FastbootTransport fakeFastbootTransport() {
  if (!_channelInstalled) {
    _channelInstalled = true;
    installFakeFastbootChannel(
      state: fakeFastbootState,
      configure: configureFakeFastboot,
    );
  }
  return _FakeTransport(_device);
}

/// Everything the fake device recorded, as JSON-like values.
Map<String, Object?> fakeFastbootState() => {
  'marker': fakeFastbootMarker,
  'serial': _device.serial,
  'product': _device.product,
  'maxDownloadSize': _device.maxDownloadSize,
  'mode': _device.mode.name,
  'failFlash': _device.failFlash,
  'failures': [
    for (final failure in _device.failures) Map<String, Object?>.from(failure),
  ],
  'commands': List<String>.from(_device.commands),
  'flashCommands': List<String>.from(_device.flashCommands),
  'parts': {
    for (final entry in _device.parts.entries)
      entry.key: [for (final part in entry.value) base64Encode(part)],
  },
  'delivered': {
    for (final entry in _device.delivered.entries)
      entry.key: base64Encode(entry.value),
  },
};

/// Applies one harness command and returns the resulting state.
Map<String, Object?> configureFakeFastboot(Map<String, Object?> command) {
  if (command['reset'] == true) _device.reset();
  final product = command['product'];
  if (product is String && product.isNotEmpty) _device.product = product;
  final maxDownload = command['maxDownloadSize'];
  if (maxDownload is String && maxDownload.isNotEmpty) {
    _device.maxDownloadSize = maxDownload;
  }
  if (command.containsKey('failFlash')) {
    final fail = command['failFlash'];
    _device.failFlash = fail is String && fail.isNotEmpty ? fail : null;
    _device.failOnce = command['failOnce'] != false;
  }
  return fakeFastbootState();
}

final class _FakeDevice {
  String serial = fakeFastbootSerial;
  String product = 'sun';
  String maxDownloadSize = '0x4000';
  bool fastbootd = false;
  bool android = false;
  String? failFlash;
  bool failOnce = true;

  final commands = <String>[];
  final flashCommands = <String>[];
  final parts = <String, List<Uint8List>>{};
  final delivered = <String, Uint8List>{};
  final failures = <Map<String, Object?>>[];

  BytesBuilder? _download;

  FlashMode get mode {
    if (android) return FlashMode.android;
    if (fastbootd) return FlashMode.fastbootd;
    return FlashMode.bootloader;
  }

  void reset() {
    product = 'sun';
    maxDownloadSize = '0x4000';
    fastbootd = false;
    android = false;
    failFlash = null;
    failOnce = true;
    commands.clear();
    flashCommands.clear();
    parts.clear();
    delivered.clear();
    failures.clear();
    _download = null;
  }

  void begin() {
    _download = BytesBuilder(copy: false);
  }

  void add(List<int> bytes) {
    _download?.add(bytes);
  }

  Uint8List? take() {
    final builder = _download;
    _download = null;
    return builder?.takeBytes();
  }
}

final class _FakeTransport implements FastbootTransport {
  const _FakeTransport(this.device);

  final _FakeDevice device;

  @override
  Future<FastbootDiscovery> devices() async => FastbootDiscovery(
    devices: [
      FastbootDevice(
        serial: device.serial,
        label: 'Fake fastboot phone',
        transport: 'fake',
      ),
    ],
  );

  @override
  Future<FastbootSession> open(String serial) async {
    if (serial != device.serial) {
      throw const LinkFailure(
        blame: LinkBlame.unknown,
        name: 'NoDevice',
        message: 'The fake device is not connected.',
        stage: 'open',
      );
    }
    return _FakeSession(device);
  }
}

final class _FakeSession implements FastbootSession {
  _FakeSession(this.device);

  final _FakeDevice device;
  var _closed = false;

  @override
  String get serial => device.serial;

  @override
  Future<FastbootCommandResult> commandWithMessages(
    String command, {
    bool write = false,
  }) async => FastbootCommandResult(
    await this.command(command, write: write),
    messages: command == 'getvar:all'
        ? [
            {'kind': 'INFO', 'text': 'snapshot-update-status:none'},
            {'kind': 'INFO', 'text': 'partition-size:super:0x400000000'},
          ]
        : const [],
  );

  @override
  Future<String> command(String command, {bool write = false}) async {
    if (_closed) throw StateError('closed');
    device.commands.add(command);
    if (command == 'getvar:product') return device.product;
    if (command == 'getvar:is-userspace') {
      return device.fastbootd ? 'yes' : 'no';
    }
    if (command == 'getvar:max-download-size') return device.maxDownloadSize;
    if (command == 'getvar:current-slot') return 'a';
    if (command == 'getvar:snapshot-update-status') return 'none';
    if (command.startsWith('getvar:is-logical:')) return 'no';
    if (command == 'reboot-fastboot') {
      device.fastbootd = true;
      device.android = false;
      return '';
    }
    if (command == 'reboot-bootloader') {
      device.fastbootd = false;
      device.android = false;
      return '';
    }
    if (command == 'reboot') {
      device.android = true;
      return '';
    }
    if (command.startsWith('flash:')) {
      final partition = command.substring('flash:'.length);
      device.flashCommands.add(partition);
      final bytes = device.take();
      if (bytes != null) {
        device.delivered[partition] = bytes;
        (device.parts[partition] ??= <Uint8List>[]).add(bytes);
      }
      fakeFastbootBroadcast({
        'type': 'flash',
        'partition': partition,
        'bytes': bytes?.length ?? 0,
      });
      if (device.failFlash == partition) {
        if (device.failOnce) device.failFlash = null;
        device.failures.add({
          'partition': partition,
          'message': 'Injected e2e failure on $partition.',
        });
        fakeFastbootBroadcast({'type': 'failure', 'partition': partition});
        throw LinkFailure(
          blame: LinkBlame.device,
          name: 'FastbootFail',
          message: 'Injected e2e failure on $partition.',
          stage: 'flash',
        );
      }
      return '';
    }
    return '';
  }

  @override
  Future<void> beginDownload(int length) async {
    device.begin();
  }

  @override
  Future<void> writeDownload(Uint8List bytes) async {
    device.add(bytes);
  }

  @override
  Future<void> endDownload() async {}

  @override
  Future<void> close() async {
    _closed = true;
  }
}
