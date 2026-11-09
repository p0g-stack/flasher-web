/// A ZIP export streamed to the page's download instead of a file handle.
///
/// Android Chrome has no save-file picker, so the page registers a one-use
/// download with the service worker and hands the export a channel name
/// instead of a `FileSystemFileHandle`. The archive leaves through that
/// channel: the download grants credit, and the sink posts a chunk only when
/// the download has room for it, so the export never runs ahead of the file
/// being written and no copy lands in origin storage.
library;

import 'dart:async';
import 'dart:typed_data';

import '../pipeline/errors.dart' show CancelledException;
import 'contracts.dart';

/// The download's side of a streamed export: bytes out, credit and cancel in.
///
/// Messages from the download are `{"type": "credit", "bytes": n}` (send up to
/// `n` more bytes) and `{"type": "cancel"}` (the user stopped the download).
abstract interface class ExportStreamChannel {
  /// Starts delivering the download's messages to [handler].
  void listen(void Function(Map<String, Object?> message) handler);

  /// Posts [message] to the download: `ready` once the sink listens, a
  /// `chunk`, the final `end` or an `error`.
  void send(Map<String, Object?> message);

  /// Releases the channel. Called once, after the last message.
  void close();
}

/// A sequential [ByteSink] that feeds a streamed download.
///
/// The archive leaves as one stream, so writes must arrive in order, each at
/// exactly the bytes already written; anything else is a bug in the export,
/// not a resumable position. [write] waits for the download's credit before
/// posting a chunk, which bounds the in-flight window to the credit the
/// download granted and gives the export the browser's pace as backpressure.
///
/// [truncate] must name the bytes written: a streamed archive has no file to
/// grow or shrink, and a mismatch means the ZIP the caller describes is not
/// the ZIP it wrote. [close] ends the download when the archive was truncated
/// to its length and errors it otherwise.
final class ExportStreamSink implements ByteSink {
  ExportStreamSink(this._channel) {
    _channel.listen(_onMessage);
    // The download cannot grant credit before the worker listens: a message
    // posted to a channel with no listener yet is lost.
    _channel.send({'type': 'ready'});
  }

  final ExportStreamChannel _channel;

  int _written = 0;
  int _credit = 0;
  bool _truncated = false;
  bool _closed = false;
  bool _cancelled = false;
  final _waiters = <Completer<void>>[];

  /// The bytes the download has accepted; the archive length after
  /// [truncate].
  int get written => _written;

  void _onMessage(Map<String, Object?> message) {
    switch (message['type']) {
      case 'credit':
        final bytes = message['bytes'];
        if (bytes is num && bytes > 0) _credit += bytes.toInt();
        _release();
      case 'cancel':
        _cancelled = true;
        _release();
    }
  }

  void _release() {
    if (_waiters.isEmpty) return;
    final waiters = List<Completer<void>>.of(_waiters);
    _waiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  void _checkUsable() {
    if (_cancelled) {
      throw const CancelledException('The download was cancelled.');
    }
    if (_closed) throw StateError('stream sink is closed');
  }

  @override
  Future<void> write(Uint8List bytes, int offset) async {
    checkWriteOffset(offset);
    _checkUsable();
    if (offset != _written) {
      throw StateError(
        'stream sink writes sequentially: expected offset $_written, '
        'got $offset',
      );
    }
    var start = 0;
    while (start < bytes.length) {
      final credit = await _takeCredit();
      final count = credit < bytes.length - start
          ? credit
          : bytes.length - start;
      _credit -= count;
      _channel.send({
        'type': 'chunk',
        'bytes': Uint8List.sublistView(bytes, start, start + count),
      });
      _written += count;
      start += count;
    }
  }

  /// Waits for the download to grant credit and returns what it granted.
  Future<int> _takeCredit() async {
    while (_credit <= 0) {
      _checkUsable();
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _checkUsable();
    return _credit;
  }

  @override
  Future<void> truncate(int length) async {
    checkTruncateLength(length);
    _checkUsable();
    if (length != _written) {
      throw StateError(
        'stream sink truncate($length) does not match the $_written bytes '
        'written',
      );
    }
    _truncated = true;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _release();
    if (_truncated) {
      _channel.send({'type': 'end'});
    } else if (!_cancelled) {
      _channel.send({
        'type': 'error',
        'message': 'The ZIP export stopped before the archive was complete.',
      });
    }
    _channel.close();
  }
}
