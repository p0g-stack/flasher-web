import 'package:test/test.dart';
import 'package:flasher_web_cli/flasher_web_cli.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

void main() {
  test('the pipeline commands replace hello and digest', () {
    final commands = AppRunner().commands.keys.toSet();
    expect(
      commands,
      containsAll(['bloat', 'build', 'facts', 'inspect', 'serve']),
    );
    expect(commands, isNot(contains('hello')));
    expect(commands, isNot(contains('digest')));
  });

  test('an unknown command is a usage error', () async {
    expect(await AppRunner().run(['nope']), 64);
  });

  test('serve rejects an unknown option', () async {
    expect(await AppRunner().run(['serve', '--nope']), 64);
  });

  test('the CLI checks its own facts', () async {
    final place = await cliPlace();
    expect(place.kind, 'cli');
    expect(place.facts[Fact.processSpawn], isA<bool>());
  });
}
