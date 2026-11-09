@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:flasher_web_core/src/pipeline/errors.dart';
import 'package:flasher_web_core/src/storage/export_stream.dart';
import 'package:test/test.dart';

Uint8List bytesOf(List<int> values) => Uint8List.fromList(values);

/// The download's side, recorded: what the sink posted, and credit on demand.
final class _FakeChannel implements ExportStreamChannel {
  final sent = <Map<String, Object?>>[];
  bool closed = false;
  void Function(Map<String, Object?> message)? _handler;

  @override
  void listen(void Function(Map<String, Object?> message) handler) {
    _handler = handler;
  }

  @override
  void send(Map<String, Object?> message) => sent.add(message);

  @override
  void close() => closed = true;

  void grant(int bytes) => _handler!({'type': 'credit', 'bytes': bytes});

  void cancel() => _handler!({'type': 'cancel'});

  List<int> get chunkLengths => [
    for (final message in sent)
      if (message['type'] == 'chunk') (message['bytes'] as Uint8List).length,
  ];
}

void main() {
  test('rejects a write that does not continue the stream', () async {
    final channel = _FakeChannel();
    final sink = ExportStreamSink(channel);
    channel.grant(1024);
    await sink.write(bytesOf([1, 2, 3]), 0);

    channel.grant(1024);
    await expectLater(
      sink.write(bytesOf([4]), 4),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      sink.write(bytesOf([4]), 0),
      throwsA(isA<StateError>()),
    );
    expect(sink.written, 3);
  });

  test('rejects a truncate that does not match the bytes written', () async {
    final channel = _FakeChannel();
    final sink = ExportStreamSink(channel);
    channel.grant(1024);
    await sink.write(bytesOf([1, 2, 3]), 0);

    await expectLater(sink.truncate(4), throwsA(isA<StateError>()));
    await sink.truncate(3);
    await sink.close();

    expect(channel.sent.last['type'], 'end');
    expect(channel.closed, isTrue);
  });

  test('sends a chunk only when the download grants credit', () async {
    final channel = _FakeChannel();
    final sink = ExportStreamSink(channel);
    var completed = false;
    final write = sink.write(bytesOf([1, 2, 3, 4, 5, 6]), 0).then((_) {
      completed = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    expect(channel.sent.map((message) => message['type']), ['ready']);

    channel.grant(4);
    await Future<void>.delayed(Duration.zero);
    expect(channel.chunkLengths, [4]);
    expect(completed, isFalse);

    channel.grant(4);
    await write;
    expect(channel.chunkLengths, [4, 2]);
    expect(sink.written, 6);
  });

  test('aborts the export when the download is cancelled', () async {
    final channel = _FakeChannel();
    final sink = ExportStreamSink(channel);
    final write = sink.write(bytesOf([1, 2, 3]), 0);
    await Future<void>.delayed(Duration.zero);
    channel.cancel();

    await expectLater(write, throwsA(isA<CancelledException>()));
    await expectLater(
      sink.write(bytesOf([4]), 3),
      throwsA(isA<CancelledException>()),
    );
    await sink.close();
    expect(channel.chunkLengths, isEmpty);
    expect(channel.sent.where((message) => message['type'] == 'error'), isEmpty);
    expect(channel.closed, isTrue);
  });

  test('errors the download when the archive was never truncated', () async {
    final channel = _FakeChannel();
    final sink = ExportStreamSink(channel);
    channel.grant(1024);
    await sink.write(bytesOf([1, 2, 3]), 0);
    await sink.close();

    expect(channel.sent.last['type'], 'error');
    expect(channel.sent.where((message) => message['type'] == 'end'), isEmpty);
    expect(channel.closed, isTrue);
  });
}
