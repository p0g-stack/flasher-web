@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flasher_web_core/src/service/storage_stats.dart';
import 'package:test/test.dart';

@JS('Object.getOwnPropertyDescriptor')
external JSObject? _descriptor(JSObject target, JSString name);

@JS('Object.defineProperty')
external void _define(JSObject target, JSString name, JSObject descriptor);

@JS('Reflect.deleteProperty')
external JSBoolean _delete(JSObject target, JSString name);

void main() {
  final navigator = globalContext['navigator'] as JSObject;
  final property = 'storage'.toJS;
  JSObject? original;

  setUp(() {
    original = _descriptor(navigator, property);
    final estimate =
        {
              'quota': 2 * 1024 * 1024 * 1024,
              'usage': 2 * 1024 * 1024 * 1024,
            }.jsify()!
            as JSObject;
    final storage =
        {
              'persisted': (() => Future<JSBoolean>.value(
                false.toJS,
              ).toJS).toJS,
              'estimate': (() => Future<JSObject>.value(estimate).toJS).toJS,
            }.jsify()!
            as JSObject;
    _define(
      navigator,
      property,
      {'configurable': true, 'value': storage}.jsify()! as JSObject,
    );
  });

  tearDown(() {
    final descriptor = original;
    if (descriptor == null) {
      _delete(navigator, property);
    } else {
      _define(navigator, property, descriptor);
    }
  });

  test(
    'an exhausted origin does not declare a chosen filesystem folder full',
    () async {
      expect(await availableStoreBytes({'kind': 'opfs'}), 0);
      expect(await availableStoreBytes({'kind': 'directory'}), isNull);
    },
  );
}
