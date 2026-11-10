@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:test/test.dart';
import 'package:web_usb_grant/browser.dart';
import 'package:web_usb_grant/interop.dart';
import 'package:web_usb_grant/web_usb_grant.dart';

JSObject device({String? serial = 'serial-1'}) =>
    <String, Object?>{
          'vendorId': 0x1209,
          'productId': 0x1234,
          'serialNumber': serial,
          'productName': 'Test device',
          'manufacturerName': 'Maker',
        }.jsify()!
        as JSObject;

JSFunction script(String body) => globalContext
    .getProperty<JSFunction>('Function'.toJS)
    .callAsConstructor<JSFunction>(body.toJS);

WebUsb browser(JSObject? usb, {bool secure = true}) => WebUsb(
  backend: BrowserUsbBackend(
    usb: usb == null ? null : USB(usb),
    secureContext: secure,
  ),
);

JSObject usb({JSFunction? request, JSFunction? list}) {
  final result = JSObject();
  if (request != null) result['requestDevice'] = request;
  if (list != null) result['getDevices'] = list;
  return result;
}

TypeMatcher<UsbException> failure(UsbFailureKind kind) =>
    isA<UsbException>().having((error) => error.kind, 'kind', kind);

void main() {
  test('capability requires security and callable request/list methods', () {
    final methods = usb(
      request: script('return Promise.resolve({});'),
      list: script('return Promise.resolve([]);'),
    );
    expect(browser(methods).isSupported, isTrue);
    expect(browser(methods, secure: false).isSupported, isFalse);
    expect(browser(null).isSupported, isFalse);
    final bad = JSObject()..['requestDevice'] = 1.toJS;
    expect(browser(bad).capabilities.canRequest, isFalse);
    expect(
      browser(usb(list: methods['getDevices'] as JSFunction)).isSupported,
      isFalse,
    );
  });

  test('insecure context and missing APIs have distinct failures', () async {
    await expectLater(
      browser(null, secure: false).request(),
      throwsA(failure(UsbFailureKind.insecureContext)),
    );
    await expectLater(
      browser(null).request(),
      throwsA(failure(UsbFailureKind.unsupported)),
    );
    await expectLater(
      browser(null).granted(),
      throwsA(failure(UsbFailureKind.unsupported)),
    );
  });

  test(
    'request invokes the chooser in the calling task and preserves filters',
    () async {
      var called = false;
      JSObject? options;
      final raw = device();
      final backend = usb(
        request: ((JSObject value) {
          called = true;
          options = value;
          return Future.value(USBDevice(raw)).toJS;
        }).toJS,
        list: (() => Future.value(<USBDevice>[].toJS).toJS).toJS,
      );
      final pending = browser(backend).request(
        filters: const [
          UsbFilter(
            vendorId: 0x1209,
            productId: 0x1234,
            serialNumber: 'serial-1',
          ),
          UsbFilter(classCode: 0xff, subclassCode: 0x42, protocolCode: 3),
        ],
        exclude: const [UsbFilter(vendorId: 0x1209, productId: 2)],
      );
      expect(
        called,
        isTrue,
        reason: 'must not defer past transient activation',
      );
      final filters = (options!['filters'] as JSArray<JSObject>).toDart;
      expect(filters[0]['vendorId'].dartify(), 0x1209);
      expect(filters[0]['productId'].dartify(), 0x1234);
      expect(filters[0]['serialNumber'].dartify(), 'serial-1');
      expect(filters[0].has('classCode'), isFalse);
      expect(filters[1]['classCode'].dartify(), 0xff);
      expect(filters[1]['subclassCode'].dartify(), 0x42);
      expect(filters[1]['protocolCode'].dartify(), 3);
      final excluded =
          (options!['exclusionFilters'] as JSArray<JSObject>).toDart;
      expect(excluded.single['productId'].dartify(), 2);
      final grant = await pending;
      expect(grant.vendorId, 0x1209);
      expect(grant.productId, 0x1234);
      expect(grant.serial, 'serial-1');
      expect(grant.product, 'Test device');
      expect(grant.manufacturer, 'Maker');
      expect(grant.handle, same(raw));
    },
  );

  for (final synchronous in [false, true]) {
    for (final entry in {
      'NotFoundError': UsbFailureKind.cancelled,
      'SecurityError': UsbFailureKind.permission,
      'NotAllowedError': UsbFailureKind.permission,
      'NetworkError': UsbFailureKind.other,
    }.entries) {
      test(
        '${synchronous ? 'throw' : 'reject'} ${entry.key} keeps DOM details',
        () async {
          final verb = synchronous
              ? 'throw error;'
              : 'return Promise.reject(error);';
          final backend = usb(
            request: script('''
          const error = new DOMException('original message', '${entry.key}');
          Object.defineProperty(error, 'stack', {value: 'original stack'});
          $verb
        '''),
          );
          try {
            await browser(backend).request();
            fail('request must not succeed');
          } on UsbException catch (error) {
            expect(error.kind, entry.value);
            expect(error.name, entry.key);
            expect(error.message, 'original message');
            expect(error.stack, 'original stack');
            expect(error.cause, isNotNull);
          }
        },
      );
    }
  }

  test('a rejection without DOM fields still preserves its cause', () async {
    final backend = usb(
      request: script("return Promise.reject('plain reason');"),
    );
    await expectLater(
      browser(backend).request(),
      throwsA(
        failure(UsbFailureKind.other)
            .having((e) => e.message, 'message', contains('plain reason')),
      ),
    );
  });

  test('granted lists metadata without request, open, or claim', () async {
    final raw = device();
    raw['open'] = script("throw new Error('must not open');");
    raw['claimInterface'] = script("throw new Error('must not claim');");
    final backend = usb(
      request: script("throw new Error('must not show chooser');"),
      list: (() => Future.value([USBDevice(raw)].toJS).toJS).toJS,
    );
    final grants = await browser(backend).granted();
    expect(grants.single.requireSerial(), 'serial-1');
    expect(grants.single.handle, same(raw));
  });

  test('worker-style context can list without a chooser', () async {
    final api = browser(usb(list: script('return Promise.resolve([]);')));
    expect(api.capabilities.canList, isTrue);
    expect(api.capabilities.canRequest, isFalse);
    expect(await api.granted(), isEmpty);
    await expectLater(
      api.request(),
      throwsA(failure(UsbFailureKind.unsupported)),
    );
  });

  test('enumeration failure is not a cancelled chooser', () async {
    final api = browser(
      usb(
        list: script(
          "return Promise.reject(new DOMException('gone', 'NotFoundError'));",
        ),
      ),
    );
    await expectLater(api.granted(), throwsA(failure(UsbFailureKind.other)));
  });

  test('serial is optional until a consumer requires it', () async {
    for (final serial in <String?>[null, '', '   ']) {
      final raw = device(serial: serial);
      final api = browser(
        usb(request: ((JSObject _) => Future.value(USBDevice(raw)).toJS).toJS),
      );
      final grant = await api.request();
      expect(grant.serial, serial);
      expect(grant.requireSerial, throwsA(failure(UsbFailureKind.noSerial)));
    }
  });

  test(
    'a fake backend is injected without browser globals or build defines',
    () async {
      final fake = _FakeBackend();
      final api = WebUsb(backend: fake);
      final pending = api.request(filters: const [UsbFilter(vendorId: 7)]);
      expect(fake.requested, isTrue);
      expect(fake.filters.single.vendorId, 7);
      expect((await pending).serial, 'fake');
      expect((await api.granted()).single.serial, 'fake');
    },
  );

  test('raw transfer bindings preserve DataView and byte count', () async {
    final raw = device();
    raw['transferIn'] = script(
      "return Promise.resolve({status: 'ok', data: new DataView(new Uint8Array([1, 2, 3]).buffer)});",
    );
    raw['transferOut'] = script(
      "return Promise.resolve({status: 'ok', bytesWritten: arguments[1].byteLength});",
    );
    final handle = USBDevice(raw);
    final input = await handle.transferIn(1, 3).toDart;
    expect(input.status, 'ok');
    expect(input.data!.toDart.getUint8(2), 3);
    final output = await handle
        .transferOut(2, JSUint8Array.withLength(4))
        .toDart;
    expect(output.bytesWritten, 4);
  });
}

final class _FakeBackend implements UsbBackend {
  bool requested = false;
  List<UsbFilter> filters = const [];
  final _grant = UsbGrant(
    vendorId: 1,
    productId: 2,
    serial: 'fake',
    handle: Object(),
  );

  @override
  UsbCapabilities get capabilities => const UsbCapabilities(
    secureContext: true,
    canRequest: true,
    canList: true,
  );

  @override
  Future<UsbGrant> request({
    List<UsbFilter> filters = const [],
    List<UsbFilter> exclude = const [],
  }) {
    requested = true;
    this.filters = filters;
    return Future.value(_grant);
  }

  @override
  Future<List<UsbGrant>> granted() => Future.value([_grant]);
}
