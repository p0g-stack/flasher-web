import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'contracts.dart';
import 'export_stream.dart';
import 'web/handle_sink.dart';

/// Opens the export's destination.
///
/// A save-picker `FileSystemFileHandle` writes straight into the file the user
/// chose. `{"kind": "stream", "channel": "<name>"}` is the service worker's
/// download instead: this browser has no save picker, so the page registered a
/// one-use download and the archive leaves over the broadcast channel named
/// here. Both truncate an existing destination and neither writes into the
/// origin's storage.
Future<ByteSink> openExportSink(Object? destination) async {
  if (destination is Map && destination['kind'] == 'stream') {
    final channel = destination['channel'];
    if (channel is! String || channel.isEmpty) {
      throw ArgumentError.value(
        destination,
        'destination',
        'must be {"kind": "stream", "channel": "<name>"}',
      );
    }
    return ExportStreamSink(_BroadcastChannel.open(channel));
  }
  try {
    return await HandleSink.open(destination as web.FileSystemFileHandle);
  } on TypeError {
    throw ArgumentError.value(
      destination,
      'destination',
      'must be the FileSystemFileHandle from the save picker',
    );
  }
}

/// The page's download, over the broadcast channel it registered.
final class _BroadcastChannel implements ExportStreamChannel {
  _BroadcastChannel(this._channel);

  factory _BroadcastChannel.open(String name) =>
      _BroadcastChannel(web.BroadcastChannel(name));

  final web.BroadcastChannel _channel;

  @override
  void listen(void Function(Map<String, Object?> message) handler) {
    _channel.onmessage = ((web.MessageEvent event) {
      final message = _readMessage(event.data);
      if (message != null) handler(message);
    }).toJS;
  }

  @override
  void send(Map<String, Object?> message) {
    _channel.postMessage(message.jsify());
  }

  @override
  void close() {
    _channel.onmessage = null;
    _channel.close();
  }
}

/// The `credit` or `cancel` a download message carries, without its bytes.
Map<String, Object?>? _readMessage(JSAny? data) {
  if (data == null || !data.isA<JSObject>()) return null;
  final object = data as JSObject;
  final message = <String, Object?>{};
  final type = object.getProperty<JSAny?>('type'.toJS);
  if (type != null && type.isA<JSString>()) {
    message['type'] = (type as JSString).toDart;
  }
  final bytes = object.getProperty<JSAny?>('bytes'.toJS);
  if (bytes != null && bytes.isA<JSNumber>()) {
    message['bytes'] = (bytes as JSNumber).toDartDouble;
  }
  return message;
}
