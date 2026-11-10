import 'dart:async';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:logging/logging.dart';

import '../native/native.dart';
import '../rust/api/fastboot.dart' as rust;

/// The app's native/WebUSB fastboot transport. The Rust crate owns discovery,
/// protocol, and streaming; this adapter only loads the library, maps typed
/// failures, and keeps one operation in flight per session.
FastbootTransport nativeFastbootTransport() => const _NativeFastbootTransport();

const int _maxChunk = 1024 * 1024;
final _log = Logger('link.fastboot');

final class _NativeFastbootTransport implements FastbootTransport {
  const _NativeFastbootTransport();

  @override
  Future<FastbootDiscovery> devices() async {
    await _requireNative('devices');
    try {
      final reply = await rust.fastbootDevices();
      final failure = reply.failure;
      if (failure != null) throw _failure(failure);
      return FastbootDiscovery(
        devices: [
          for (final device in reply.devices)
            FastbootDevice(
              serial: device.serial,
              label: device.label,
              transport: device.transport,
            ),
        ],
        failures: [
          for (final item in reply.discoveryFailures)
            FastbootDiscoveryFailure(
              serial: item.serial,
              label: item.label,
              failure: _failure(item.failure),
            ),
        ],
      );
    } on LinkFailure {
      rethrow;
    } on Object catch (error, stack) {
      throw _bridgeFailure('devices', error, stack);
    }
  }

  @override
  Future<FastbootSession> open(String serial) async {
    if (serial.isEmpty) {
      throw const LinkFailure(
        blame: LinkBlame.unknown,
        source: 'caller',
        name: 'EmptySerial',
        message: 'Refusing an empty fastboot serial.',
        stage: 'open',
      );
    }
    await _requireNative('open');
    try {
      final reply = await rust.fastbootOpen(serial: serial);
      final failure = reply.failure;
      if (failure != null || reply.handle == 0) {
        throw failure == null
            ? const LinkFailure(
                blame: LinkBlame.unknown,
                source: 'frb',
                name: 'EmptyHandle',
                message: 'The native transport returned no session handle.',
                stage: 'open',
                sessionRetired: true,
              )
            : _failure(failure);
      }
      if (reply.serial != serial) {
        await _closeQuietly(reply.handle);
        throw LinkFailure(
          blame: LinkBlame.unknown,
          source: 'native',
          name: 'SerialMismatch',
          message: 'The transport opened ${reply.serial} instead of $serial.',
          stage: 'open',
        );
      }
      return _NativeFastbootSession(reply.handle, reply.serial);
    } on LinkFailure {
      rethrow;
    } on Object catch (error, stack) {
      throw _bridgeFailure('open', error, stack);
    }
  }
}

final class _NativeFastbootSession implements FastbootSession {
  _NativeFastbootSession(this._handle, this.serial);

  int _handle;
  @override
  final String serial;
  bool _closed = false;
  bool _busy = false;
  int _expected = 0;
  int _sent = 0;

  bool get _downloading => _expected > 0;

  @override
  Future<String> command(String command, {bool write = false}) async =>
      (await commandWithMessages(command, write: write)).value;

  @override
  Future<FastbootCommandResult> commandWithMessages(String command, {bool write = false}) {
    return _invoke('command', (handle) async {
      final reply = await rust.fastbootCommand(
        handle: handle,
        command: command,
        write: write,
      );
      _throwIfFailure(reply.failure);
      _logMessages(reply.messages);
      return FastbootCommandResult(reply.value, messages: [
        for (final message in reply.messages) {'kind': message.kind, 'text': message.text},
      ]);
    });
  }

  @override
  Future<void> beginDownload(int length) {
    if (length <= 0 || length > 0xFFFFFFFF) {
      throw LinkFailure(
        blame: LinkBlame.unknown,
        source: 'caller',
        name: 'InvalidLength',
        message: 'Download length $length is outside 1..0xFFFFFFFF.',
        stage: 'beginDownload',
      );
    }
    if (_downloading) {
      throw const LinkFailure(
        blame: LinkBlame.unknown,
        source: 'caller',
        name: 'Busy',
        message: 'A download is already in progress.',
        stage: 'beginDownload',
      );
    }
    return _invoke('beginDownload', (handle) async {
      final reply = await rust.fastbootBeginDownload(
        handle: handle,
        length: length,
      );
      _throwIfFailure(reply.failure);
      _logMessages(reply.messages);
      _expected = length;
      _sent = 0;
    });
  }

  @override
  Future<void> writeDownload(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const LinkFailure(
        blame: LinkBlame.unknown,
        source: 'caller',
        name: 'EmptyChunk',
        message: 'An empty download chunk is not sent.',
        stage: 'writeDownload',
      );
    }
    if (bytes.length > _maxChunk) {
      throw LinkFailure(
        blame: LinkBlame.unknown,
        source: 'caller',
        name: 'ChunkTooLarge',
        message: 'Chunk is ${bytes.length} bytes; the maximum is $_maxChunk.',
        stage: 'writeDownload',
      );
    }
    if (!_downloading) {
      throw const LinkFailure(
        blame: LinkBlame.unknown,
        source: 'caller',
        name: 'NotDownloading',
        message: 'writeDownload requires beginDownload first.',
        stage: 'writeDownload',
      );
    }
    if (_sent + bytes.length > _expected) {
      throw LinkFailure(
        blame: LinkBlame.unknown,
        source: 'caller',
        name: 'Overrun',
        message:
            'Chunk ends at ${_sent + bytes.length}, past the declared '
            'download of $_expected bytes.',
        stage: 'writeDownload',
      );
    }
    return _invoke('writeDownload', (handle) async {
      final reply = await rust.fastbootWriteDownload(
        handle: handle,
        bytes: bytes,
      );
      _throwIfFailure(reply.failure);
      _sent += bytes.length;
    });
  }

  @override
  Future<String> endDownload() async {
    if (!_downloading) {
      throw const LinkFailure(
        blame: LinkBlame.unknown,
        source: 'caller',
        name: 'NotDownloading',
        message: 'endDownload requires beginDownload first.',
        stage: 'endDownload',
      );
    }
    if (_sent != _expected) {
      final failure = LinkFailure(
        blame: LinkBlame.unknown,
        source: 'caller',
        name: 'Incomplete',
        message: 'Only $_sent of $_expected download bytes were sent.',
        stage: 'endDownload',
        sessionRetired: true,
      );
      final handle = _handle;
      _closed = true;
      _handle = 0;
      _expected = 0;
      _sent = 0;
      await _closeQuietly(handle);
      throw failure;
    }
    return _invoke('endDownload', (handle) async {
      try {
        final reply = await rust.fastbootEndDownload(handle: handle);
        _throwIfFailure(reply.failure);
        _logMessages(reply.messages);
        return reply.value;
      } finally {
        _expected = 0;
        _sent = 0;
      }
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    if (_busy) {
      throw const LinkFailure(
        blame: LinkBlame.unknown,
        source: 'caller',
        name: 'Busy',
        message: 'Cannot close while another operation is in flight.',
        stage: 'close',
      );
    }
    _closed = true;
    final handle = _handle;
    _handle = 0;
    if (handle == 0) return;
    try {
      final reply = await rust.fastbootClose(handle: handle);
      _throwIfFailure(reply.failure);
    } on LinkFailure {
      rethrow;
    } on Object catch (error, stack) {
      throw _bridgeFailure('close', error, stack);
    }
  }

  Future<T> _invoke<T>(
    String stage,
    Future<T> Function(int handle) operation,
  ) async {
    if (_closed) {
      throw LinkFailure(
        blame: LinkBlame.unknown,
        source: 'native',
        name: 'Closed',
        message: 'This fastboot session is retired; open the device again.',
        stage: stage,
        sessionRetired: true,
      );
    }
    if (_busy) {
      throw LinkFailure(
        blame: LinkBlame.unknown,
        source: 'caller',
        name: 'Busy',
        message: 'Another fastboot operation is already in flight.',
        stage: stage,
      );
    }
    _busy = true;
    final handle = _handle;
    try {
      return await operation(handle);
    } on LinkFailure catch (error) {
      if (_retires(error)) {
        _closed = true;
        _handle = 0;
      }
      rethrow;
    } on Object catch (error, stack) {
      _closed = true;
      _handle = 0;
      throw _bridgeFailure(stage, error, stack);
    } finally {
      _busy = false;
    }
  }

  /// Only the failure's own lifecycle flag retires a session; blame and error
  /// names never decide it.
  bool _retires(LinkFailure error) => error.sessionRetired;
}

Future<void> _requireNative(String stage) async {
  if (await loadNative()) return;
  final load = nativeLoadFailure;
  throw LinkFailure(
    blame: LinkBlame.unknown,
    source: 'native',
    name: load?.name ?? 'Unavailable',
    message:
        load?.message ??
        'The Rust fastboot transport is not available in this place.',
    stage: stage,
    stack: load?.stack ?? '',
  );
}

Future<void> _closeQuietly(int handle) async {
  if (handle == 0) return;
  try {
    await rust.fastbootClose(handle: handle);
  } on Object {
    // The original failure is the one worth surfacing.
  }
}

void _throwIfFailure(rust.FastbootFailure? failure) {
  if (failure != null) throw _failure(failure);
}

LinkFailure _failure(rust.FastbootFailure failure) {
  _logMessages(failure.messages);
  return LinkFailure(
    blame: LinkBlame.values.byName(failure.blame),
    source: failure.source,
    sessionRetired: failure.sessionRetired,
    name: failure.name,
    message: failure.message,
    stage: failure.stage,
    uncertain: failure.uncertain,
    disconnectObserved: failure.disconnectObserved,
    stack: failure.stack,
    causes: failure.causes,
    cleanupErrors: failure.cleanupErrors,
    messages: [
      for (final message in failure.messages)
        {'kind': message.kind, 'text': message.text},
    ],
  );
}

void _logMessages(List<rust.FastbootMessage> messages) {
  for (final message in messages) {
    _log.info('${message.kind}: ${message.text}');
  }
}

LinkFailure _bridgeFailure(String stage, Object error, StackTrace stack) =>
    LinkFailure(
      blame: LinkBlame.unknown,
      source: 'frb',
      name: 'Bridge',
      message: '$error',
      stage: stage,
      sessionRetired: true,
      stack: '$stack',
      causes: [error.runtimeType.toString()],
    );
