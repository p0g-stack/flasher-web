import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// `navigator.hardwareConcurrency` of the page or worker; one when absent.
int cpuCount() {
  final navigator = globalContext['navigator'];
  if (navigator == null || !navigator.isA<JSObject>()) return 1;
  final value = (navigator as JSObject)['hardwareConcurrency'];
  if (value == null || !value.isA<JSNumber>()) return 1;
  final count = (value as JSNumber).toDartInt;
  return count > 0 ? count : 1;
}
