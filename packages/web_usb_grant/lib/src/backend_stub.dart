// SPDX-License-Identifier: LGPL-3.0-or-later

import 'contract.dart';

UsbBackend createBackend() => const _UnsupportedUsb();

final class _UnsupportedUsb implements UsbBackend {
  const _UnsupportedUsb();

  @override
  UsbCapabilities get capabilities => const UsbCapabilities(
    secureContext: false,
    canRequest: false,
    canList: false,
  );

  @override
  Future<UsbGrant> request({
    List<UsbFilter> filters = const [],
    List<UsbFilter> exclude = const [],
  }) => Future.error(_error);

  @override
  Future<List<UsbGrant>> granted() => Future.error(_error);

  static const _error = UsbException(
    UsbFailureKind.unsupported,
    'This execution context does not expose WebUSB.',
  );
}
