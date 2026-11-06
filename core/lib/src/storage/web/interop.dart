import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// `fetch` from the page or a Web Worker.
@JS('fetch')
external JSPromise<web.Response> webFetch(JSAny input, [web.RequestInit init]);

/// The OPFS root directory (`navigator.storage.getDirectory()`).
Future<web.FileSystemDirectoryHandle> opfsRoot() async {
  final navigator = globalContext['navigator'] as JSObject?;
  if (navigator == null) {
    throw StateError('no navigator in this context');
  }
  final storage = navigator['storage'] as JSObject?;
  if (storage == null) {
    throw StateError('navigator.storage is not available');
  }
  final promise = storage.callMethod<JSPromise<web.FileSystemDirectoryHandle>>(
    'getDirectory'.toJS,
  );
  return promise.toDart;
}

/// The entries of [directory], as `[name, handle]` pairs.
///
/// package:web 1.1.2 does not bind `entries()`'s async iterator, so this uses
/// the well-known `Symbol.asyncIterator` protocol directly. It works in the
/// page and in a worker.
Future<List<web.FileSystemHandle>> directoryEntries(
  web.FileSystemDirectoryHandle directory,
) async {
  final iterable = directory.callMethod<JSObject>('entries'.toJS);
  final symbol = (globalContext['Symbol'] as JSObject).getProperty<JSAny>(
    'asyncIterator'.toJS,
  );
  final iterator =
      iterable.getProperty<JSFunction>(symbol).callAsFunction(iterable)
          as JSObject;
  final handles = <web.FileSystemHandle>[];
  while (true) {
    final step = await iterator
        .callMethod<JSPromise<JSObject>>('next'.toJS)
        .toDart;
    final done = (step['done'] as JSBoolean?)?.toDart ?? true;
    if (done) break;
    final pair = step['value'] as JSArray<JSAny>;
    handles.add(pair.toDart[1] as web.FileSystemHandle);
  }
  return handles;
}

/// Whether [handle] has the named method (for features a browser may lack).
bool hasMethod(JSObject handle, String name) => handle.has(name);
