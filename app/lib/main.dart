import 'package:flutter/material.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

import 'app.dart';
import 'runtime.dart';

void main() {
  logTo(debugPrint, level: Level.ALL);
  runApp(FlasherApp(runtime: createRuntime()));
}
