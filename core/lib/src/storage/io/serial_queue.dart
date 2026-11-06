/// Runs actions one at a time, in call order.
///
/// A `RandomAccessFile` has one cursor. Reads and writes on one source or sink
/// therefore cannot overlap, even though the caller may issue them without
/// awaiting.
final class SerialQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
