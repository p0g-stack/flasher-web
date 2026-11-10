import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'contracts.dart';
import 'ota_file_workspace.dart';
import 'web/blob_source.dart';
import 'web/handle_sink.dart';
import 'web/handle_workspace.dart';
import 'web/interop.dart';

@JS('indexedDB')
external web.IDBFactory get _indexedDb;

Future<Workspace> openOtaDestination(Object? destination, String key) async {
  final handle = destination as web.FileSystemFileHandle;
  final root = await opfsRoot();
  final saves = await root
      .getDirectoryHandle(
        'ota-saves',
        web.FileSystemGetDirectoryOptions(create: true),
      )
      .toDart;
  final directory = await saves
      .getDirectoryHandle(key, web.FileSystemGetDirectoryOptions(create: true))
      .toDart;
  final metadata = HandleWorkspace(directory);
  final database = await _database();
  try {
    final previous = await _get(database, key);
    final same =
        previous != null && (await handle.isSameEntry(previous).toDart).toDart;
    if (!same) await metadata.delete('ota-cache');
    await _put(database, key, handle);
  } finally {
    database.close();
  }
  return OtaFileWorkspace(
    metadata: metadata,
    openFile: () async => BlobSource(await handle.getFile().toDart),
    writeFile: (keep) => HandleSink.open(handle, keepExisting: keep),
    fileSize: () async => (await handle.getFile().toDart).size,
  );
}

Future<web.IDBDatabase> _database() async {
  final completer = Completer<web.IDBDatabase>();
  final request = _indexedDb.open('flasher-ota-downloads', 1);
  request.onupgradeneeded = ((web.Event _) {
    (request.result as web.IDBDatabase).createObjectStore('handles');
  }).toJS;
  request.onsuccess = ((web.Event _) => completer.complete(
    request.result as web.IDBDatabase,
  )).toJS;
  request.onerror = ((web.Event _) => completer.completeError(
    StateError('Cannot remember OTA download destination'),
  )).toJS;
  return completer.future;
}

Future<web.FileSystemFileHandle?> _get(
  web.IDBDatabase database,
  String key,
) async {
  final completer = Completer<web.FileSystemFileHandle?>();
  final request = database
      .transaction('handles'.toJS)
      .objectStore('handles')
      .get(key.toJS);
  request.onsuccess = ((web.Event _) {
    final value = request.result;
    completer.complete(
      value == null || value.isUndefinedOrNull
          ? null
          : value as web.FileSystemFileHandle,
    );
  }).toJS;
  request.onerror = ((web.Event _) => completer.completeError(
    StateError('Cannot read saved OTA destination'),
  )).toJS;
  return completer.future;
}

Future<void> _put(
  web.IDBDatabase database,
  String key,
  web.FileSystemFileHandle handle,
) async {
  final completer = Completer<void>();
  final transaction = database.transaction('handles'.toJS, 'readwrite');
  transaction.objectStore('handles').put(handle, key.toJS);
  transaction.oncomplete = ((web.Event _) => completer.complete()).toJS;
  transaction.onerror = ((web.Event _) => completer.completeError(
    StateError('Cannot remember saved OTA destination'),
  )).toJS;
  transaction.onabort = transaction.onerror;
  return completer.future;
}
