import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flasher_web_core/flasher_web_core.dart';

/// One build, isolated in its own OS process under the parent's RLIMIT_CPU.
Future<void> main(List<String> arguments) async {
  final requestPath = _option(arguments, '--request');
  if (requestPath == null) {
    stderr.writeln('usage: build_worker --request <json>');
    exitCode = 64;
    return;
  }
  final Map<String, Object?> request;
  try {
    final decoded = jsonDecode(await File(requestPath).readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('request must be a JSON object');
    }
    request = Map<String, Object?>.from(decoded);
  } on Object catch (error) {
    stderr.writeln('invalid request: $error');
    exitCode = 64;
    return;
  }

  Map<String, Object?>? result;
  Object? failure;
  try {
    await for (final event in buildFlasher(request)) {
      if (event['type'] == 'result') {
        result = event;
      }
      stdout.writeln(jsonEncode(event));
    }
  } on Object catch (error, stack) {
    failure = error;
    stderr.writeln(error);
    stderr.writeln(stack);
  }
  await stdout.flush();
  if (failure != null || result == null) {
    stdout.writeln(
      jsonEncode({
        'type': 'error',
        'error': '$failure',
      }),
    );
    await stdout.flush();
    exitCode = 2;
    return;
  }
  exitCode = 0;
}

String? _option(List<String> arguments, String name) {
  for (var index = 0; index < arguments.length - 1; index++) {
    if (arguments[index] == name) return arguments[index + 1];
  }
  return null;
}
