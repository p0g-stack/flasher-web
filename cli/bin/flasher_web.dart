import 'dart:io';

import 'package:flasher_web_cli/flasher_web_cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await AppRunner().run(args);
}
