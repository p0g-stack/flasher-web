# web_usb_grant

Pure Dart WebUSB grants and raw WebUSB extension types, using `package:web` and
`dart:js_interop`. No Flutter, platform channels, native code, transport policy,
or dependency on flasher_web. JavaScript and Wasm builds use the same backend.
The name returned HTTP 404 from `https://pub.dev/api/packages/web_usb_grant` on
2026-11-09; that is an availability observation, not a reserved name.

## Grants

```dart
import 'package:web_usb_grant/web_usb_grant.dart';

final usb = WebUsb();

// In a button handler, before any await:
final pending = usb.request(
  filters: const [UsbFilter(vendorId: 0x1209)],
  exclude: const [UsbFilter(vendorId: 0x1209, productId: 2)],
);
final grant = await pending;
```

`request()` invokes the browser chooser synchronously before returning its
Future. The caller must call it in a user gesture, before any await. Filters
and exclusion filters have the WICG WebUSB meanings; omitted fields stay
omitted, and the browser validates their combinations and numeric ranges.

`isSupported` probes secure context plus callable request/list APIs;
`capabilities` exposes those facts separately. A worker can support
`granted()` without supporting `request()`. Neither grant operation opens,
claims, or transfers to a device. Secure contexts (HTTPS or localhost) and a
browser implementing WebUSB are required; embedded contexts can also be
restricted by Permissions Policy. A successful capability probe is not a
permission grant.

`UsbGrant` contains vendor/product IDs, nullable serial/product/manufacturer
names, and the raw device handle. Missing serials are valid WebUSB grants;
consumers that require a stable identity explicitly call `requireSerial()`,
which reports `noSerial`. Do not send the raw handle to a worker: enumerate
existing grants there and match the required serial.

`UsbException` distinguishes `cancelled` (`NotFoundError` from the chooser),
`permission` (`SecurityError` or `NotAllowedError`), `insecureContext`,
`unsupported`, `noSerial`, and `other`. Original DOMException name, message,
stack and cause are retained. Enumeration failures are never classified as a
cancelled chooser. Request cancellation throws; it does not return an empty
grant or collapse into permission denial.

Import `interop.dart` for the missing WebUSB extension types: USB/device,
filters/options, configuration/interface/alternate/endpoint descriptors,
control-transfer parameters, transfer/isochronous results, and connection
events. String enums use WebIDL spellings. Those raw methods retain the browser
API's permissions and promise semantics rather than applying grant-error
mapping. `UsbGrant.handle` can be cast to `USBDevice` on the web.

## Injection and checks

`WebUsb(backend: fake)` accepts any `UsbBackend`; no compile-time fake define or
browser-global mutation is needed. Fake backends implement the same synchronous
request contract. Browser tests can inject a synthetic USB object using
`BrowserUsbBackend` from `browser.dart`.

```sh
CHROME_EXECUTABLE=/usr/bin/google-chrome-stable dart test -p chrome
```

Tests cover same-task chooser invocation, filtering/exclusion, metadata and raw
handles, serial policy, refusal versus cancellation, DOM diagnostics,
chooser-free discovery, worker capabilities, injection, and transfer results.
They do not request permission for or access real hardware.

## Home and dependency pin

This reusable package starts inside its first consuming app at
`flasher_web/packages/web_usb_grant`, like `packages/device_link`. The app uses
`path: ../packages/web_usb_grant` and the root workspace includes it, so a fresh
clone needs no unpublished remote or sibling checkout. No global pub override
or machine-specific path is required.

Promotion is an owner action when the package leaves its first consumer:
move it to `github.com/p0g-stack/web_usb_grant`, remove the workspace-only
`resolution` setting, and replace the app's path dependency with the established
`git: {url: https://github.com/p0g-stack/web_usb_grant, ref: <full SHA>}` convention.
Keep that SHA aligned with its upstream commit before publication. No remote
repository or publication is created by this change.

## License and adoption tradeoff

LGPL-3.0-or-later (`LICENSE`, with the incorporated GPL text in `COPYING`),
matching p0g-stack's common license direction. Original implementation is
extracted from flasher_web; binding declarations follow the
[WICG WebUSB specification](https://wicg.github.io/webusb/).

MIT consumers such as trezor_flutter can retain their own application license,
but adopting this package is not an MIT-only dependency swap: they must comply
with LGPL notices, library source/modification requirements, and the combined
work's ability to replace/recombine the library. For compiled JavaScript/Wasm,
that can require distributing suitable application source/build material, not
merely linking a source URL. This adds adoption/compliance cost compared with
an MIT package; preserving a single copyleft policy is the deliberate tradeoff.
No consumer's license is silently changed and no linking exception is implied.
