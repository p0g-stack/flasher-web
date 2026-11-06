@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:squadron_process/io.dart';
import 'package:squadron_process/squadron_process.dart';
import 'package:test/test.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

void main() {
  test('the flasher service runs in the CLI as a process place', () async {
    final dir = await Directory.systemTemp.createTemp('p0g');
    addTearDown(() => dir.delete(recursive: true));
    final session = '${dir.path}/place.json';
    final place = ProcessPlace(
      launcher: const IoProcessLauncher(),
      store: FileEndpointStore(session),
      command: ProcessCommand(
        Platform.resolvedExecutable,
        arguments: [
          'run',
          'bin/flasher_web.dart',
          'serve',
          '--session-file',
          session,
          '--grace-ms',
          '200',
        ],
      ),
      readyTimeout: const Duration(minutes: 2),
    );

    final worker = place.bind(FlasherServiceWorker(), service: 'flasher');
    addTearDown(worker.terminate);
    final environment = await worker.environment();
    expect(environment['facts'], isA<List>());
    expect(environment['native'], isA<bool>());
    expect((await place.facts())[Fact.processSpawn], isA<bool>());
  }, timeout: const Timeout(Duration(minutes: 3)));
}
