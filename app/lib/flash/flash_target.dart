/// The OTA-direct package one flash attempt writes.
///
/// The service reads the OTA in place and the verified bloat images from the
/// bloat store; no built job, ZIP or output folder exists.
final class FlashTarget {
  const FlashTarget({
    required Map<String, Object?> ota,
    Map<String, Object?>? base,
    required Map<String, Object?> bloat,
    required this.selection,
    required this.label,
    this.vulnerableAbl,
  }) : virtualOta = ota,
       virtualBase = base,
       virtualBloat = bloat;

  /// The exact table selection `{device, kind, region}` the flash is for.
  final Map<String, Object?> selection;

  /// A human label for the package row.
  final String label;
  final bool? vulnerableAbl;

  /// The OTA input `{kind: file|url|catalog, ...}`.
  final Map<String, Object?> virtualOta;

  /// The BASE OTA input an Ace 6 conversion reads, or null for every other
  /// selection. The ODM donor is never a target field: the service matches it
  /// in the catalog.
  final Map<String, Object?>? virtualBase;

  /// The bloat store `{kind: opfs}` or a directory handle.
  final Map<String, Object?> virtualBloat;

  /// The only virtual input the service accepts: the OTA source, the optional
  /// BASE OTA and the verified bloat store. No output store and no built job
  /// are named.
  Map<String, Object?> get virtualRequest => {
    'ota': virtualOta,
    if (virtualBase != null) 'base': virtualBase,
    'bloat': virtualBloat,
  };

  String get device => '${selection['device'] ?? ''}';
  String get kind => '${selection['kind'] ?? ''}';
  String get region => '${selection['region'] ?? ''}';

  @override
  String toString() => label;
}

/// One prompt the plan still needs an explicit answer for.
final class FlashPrompt {
  const FlashPrompt({
    required this.id,
    required this.question,
    required this.choices,
    required this.selected,
  });

  factory FlashPrompt.fromMap(Map<String, Object?> map) {
    final choices = map['choices'];
    return FlashPrompt(
      id: '${map['id'] ?? ''}',
      question: '${map['question'] ?? ''}',
      choices: choices is List
          ? [
              for (final choice in choices)
                if (choice is String) choice,
            ]
          : const [],
      selected: map['selected'] is String ? map['selected']! as String : null,
    );
  }

  final String id;
  final String question;
  final List<String> choices;

  /// The server's current selection, if any. The UI still requires the user
  /// to answer because a default must not silently confirm a choice.
  final String? selected;
}

/// The parsed response of `prepareFlash`.
final class PreparedFlash {
  const PreparedFlash({
    required this.raw,
    required this.token,
    required this.serial,
    required this.mode,
    required this.modeOk,
    required this.resolved,
    required this.steps,
    required this.confirmation,
    required this.prompts,
    required this.warnings,
    required this.format,
    required this.version,
    required this.job,
  });

  factory PreparedFlash.fromMap(Map<String, Object?> map) {
    List<String> strings(Object? value) => value is List
        ? [
            for (final item in value)
              if (item is String) item,
          ]
        : const [];
    final prompts = map['prompts'];
    final confirmation = map['confirmation'];
    return PreparedFlash(
      raw: Map<String, Object?>.unmodifiable(map),
      token: map['token'] is String ? map['token']! as String : null,
      serial: '${map['serial'] ?? ''}',
      mode: '${map['mode'] ?? ''}',
      modeOk: map['modeOk'] == true,
      resolved: map['resolved'] == true,
      steps: strings(map['steps']),
      confirmation: strings(confirmation),
      prompts: prompts is List
          ? [
              for (final prompt in prompts)
                if (prompt is Map)
                  FlashPrompt.fromMap(Map<String, Object?>.from(prompt)),
            ]
          : const [],
      warnings: strings(map['warnings']),
      format: '${map['format'] ?? ''}',
      version: '${map['version'] ?? ''}',
      job: '${map['job'] ?? ''}',
    );
  }

  final Map<String, Object?> raw;
  final String? token;
  final String serial;

  final String mode;
  final bool modeOk;
  final bool resolved;
  final List<String> steps;
  final List<String> confirmation;
  final List<FlashPrompt> prompts;
  final List<String> warnings;
  final String format;
  final String version;
  final String job;

  bool get hasToken => token != null && token!.isNotEmpty;
}

/// Short guidance only. Original evidence stays in the log and receipt.
String describeLinkFailure(Object? value) {
  if (value is! Map) return '$value';
  final name = '${value['name'] ?? ''}';
  final message = '${value['message'] ?? ''}'.trim();
  final blame = '${value['blame'] ?? 'unknown'}';
  if (value['uncertain'] == true) {
    return 'The phone did not confirm completion and may still be writing. '
        'Save the log and stop further commands; do not disconnect or retry '
        'until it is safe.';
  }
  if (name == 'InconsistentDeviceAnswers') {
    return 'The phone answers fastboot inconsistently. Unplug it, hold Power '
        'for 15 seconds to turn it off, then hold Power + Volume Down to enter '
        'fastboot, reconnect it and prepare again.';
  }
  if (name == 'FastbootFail' && blame == 'device') {
    return 'The phone refused the command${message.isEmpty ? '.' : ': $message'} '
        'Check the phone and the log before retrying.';
  }
  if (name == 'Busy' && blame == 'host') {
    return 'The USB interface is already in use. Close other flashing tabs or '
        'programs, then check the connection.';
  }
  if (blame == 'host' || name == 'SecurityError' || name == 'PermissionDenied') {
    return 'USB access was refused. Allow this site to use the phone and check '
        'your operating system’s USB permissions, then retry.';
  }
  if (blame == 'user' && name == 'NotFoundError') {
    return 'No phone was selected. Choose the phone again.';
  }
  if (name == 'FlashException') return message;
  if (const {'Timeout', 'TimeoutError', 'OperationDeadline', 'NoProgress',
      'NetworkError', 'Disconnected', 'NotFoundError', 'ShortWrite', 'UsbError',
      'NoDevice'}.contains(name)) {
    return "The phone isn't answering fastboot. Replug it or hold Power + "
        'Volume Down, then retry.';
  }
  return 'The connection could not be checked. Save the log, then check the '
      'phone and retry.';
}
