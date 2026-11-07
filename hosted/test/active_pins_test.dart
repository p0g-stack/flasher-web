import 'package:flasher_web_hosted/src/active_pins.dart';
import 'package:flasher_web_hosted/src/errors.dart';
import 'package:test/test.dart';

void main() {
  test('active pins do not expire and are bounded per job/global', () {
    final pins = ActivePinManager(maxPerJob: 2, maxTotal: 3);
    pins.acquire('job');
    pins.acquire('job');
    expect(pins.isPinned('job'), isTrue);
    expect(
      () => pins.acquire('job'),
      throwsA(
        isA<HostedException>().having(
          (error) => error.code,
          'code',
          'active_pin_limit',
        ),
      ),
    );
    pins.acquire('other');
    expect(
      () => pins.acquire('third'),
      throwsA(isA<HostedException>()),
    );
    pins.release('job');
    expect(pins.isPinned('job'), isTrue); // one operation still active
    pins.release('job');
    expect(pins.isPinned('job'), isFalse);
    pins.clear();
    expect(pins.pinnedJobs(), isEmpty);
  });
}
