/// The fake device's browser control channel.
library;

import 'dart:convert';

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'fake_fastboot.dart'
    show fakeFastbootChannelName, fakeFastbootMarker;

web.BroadcastChannel? _channel;

void installFakeFastbootChannel({
  required Map<String, Object?> Function() state,
  required Map<String, Object?> Function(Map<String, Object?>) configure,
}) {
  if (_channel != null) return;
  final channel = web.BroadcastChannel(fakeFastbootChannelName);
  channel.onmessage = ((web.MessageEvent event) {
    final data = event.data;
    if (data == null || !data.isA<JSString>()) return;
    final Object? decoded;
    try {
      decoded = jsonDecode((data as JSString).toDart);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final message = Map<String, Object?>.from(decoded);
    final op = message['op'];
    switch (op) {
      case 'state':
        _post({'type': 'state', 'state': state()});
      case 'configure':
        _post({'type': 'state', 'state': configure(message)});
      default:
        _post({
          'type': 'error',
          'message': 'Unknown fake device command: $op',
        });
    }
  }).toJS;
  _channel = channel;
  _post({'type': 'ready', 'marker': fakeFastbootMarker, 'state': state()});
}

void fakeFastbootBroadcast(Map<String, Object?> message) {
  _post(message);
}

void _post(Map<String, Object?> message) {
  _channel?.postMessage(jsonEncode(message).toJS);
}
