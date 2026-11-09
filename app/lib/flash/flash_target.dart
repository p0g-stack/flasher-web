/// One finished job selected for flashing.
///
/// The job stays in the output store; a ZIP build is read through the same
/// store and job pair, never through a temporary stage path.
final class FlashTarget {
  const FlashTarget({
    required this.job,
    required this.store,
    required this.selection,
    required this.label,
  }) : hostedSha256 = null,
       hostedBytes = null,
       virtualOta = null,
       virtualBloat = null;

  /// A local-first flash with no built package: the service reads the OTA in
  /// place and the verified bloat images from the bloat store.
  ///
  /// [job] stays empty until `prepareFlash` assigns the derived virtual job
  /// id; the controller echoes it back when executing.
  const FlashTarget.virtual({
    required Map<String, Object?> ota,
    required Map<String, Object?> bloat,
    required this.selection,
    required this.label,
  }) : job = '',
       store = const {},
       hostedSha256 = null,
       hostedBytes = null,
       virtualOta = ota,
       virtualBloat = bloat;

  /// A hosted, catalog-owned build. The service fetches the ZIP through
  /// same-origin ranges; [store] stays empty and nothing is written locally.
  const FlashTarget.hosted({
    required String jobId,
    required String sha256,
    required int bytes,
    required this.selection,
    required this.label,
  }) : job = jobId,
       store = const {},
       hostedSha256 = sha256,
       hostedBytes = bytes,
       virtualOta = null,
       virtualBloat = null;

  final String job;

  /// The service store map: `{kind: opfs}` or a directory handle.
  final Map<String, Object?> store;

  /// The exact table selection `{device, kind, region}` the job was built for.
  final Map<String, Object?> selection;

  /// A human label for the package row.
  final String label;

  /// The immutable artifact digest, for a hosted build.
  final String? hostedSha256;

  /// The exact ZIP length, for a hosted build.
  final int? hostedBytes;

  /// The OTA input `{kind: file|url|catalog, ...}`, for a virtual flash.
  final Map<String, Object?>? virtualOta;

  /// The bloat store `{kind: opfs}` or a directory handle, for a virtual flash.
  final Map<String, Object?>? virtualBloat;

  bool get isHosted => hostedSha256 != null;

  bool get isVirtual => virtualOta != null && virtualBloat != null;

  /// The only virtual input the service accepts: the OTA source and the
  /// verified bloat store. No output store and no built job are named.
  Map<String, Object?>? get virtualRequest {
    if (!isVirtual) return null;
    return {'ota': virtualOta, 'bloat': virtualBloat};
  }

  /// The only hosted input the service accepts: a capability id and the
  /// immutable digest and length. No URL or upload is ever sent.
  Map<String, Object?>? get hostedRequest {
    final sha256 = hostedSha256;
    final bytes = hostedBytes;
    if (sha256 == null || bytes == null) return null;
    return {'jobId': job, 'sha256': sha256, 'bytes': bytes};
  }

  String get device => '${selection['device'] ?? ''}';
  String get kind => '${selection['kind'] ?? ''}';
  String get region => '${selection['region'] ?? ''}';

  @override
  String toString() => '$label · $job';
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
    required this.product,
    required this.expectedProduct,
    required this.productMatches,
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
      product: '${map['product'] ?? ''}',
      expectedProduct: '${map['expectedProduct'] ?? ''}',
      productMatches: map['productMatches'] == true,
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

  /// The product the connected device reported.
  final String product;

  /// The product the selected package requires.
  final String expectedProduct;
  final bool productMatches;
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

/// Renders a structured `LinkFailure.toMap()` without losing its evidence.
String describeLinkFailure(Object? value) {
  if (value is! Map) return '$value';
  final map = Map<String, Object?>.from(value);
  final name = '${map['name'] ?? 'LinkFailure'}';
  final message = '${map['message'] ?? ''}'.trim();
  final blame = '${map['blame'] ?? ''}'.trim();
  final stage = '${map['stage'] ?? ''}'.trim();
  final uncertain = map['uncertain'] == true;
  final causes = map['causes'];
  final cleanup = map['cleanupErrors'];
  final details = <String>[
    if (blame.isNotEmpty) 'blame: $blame',
    if (stage.isNotEmpty) 'stage: $stage',
    'uncertain: ${uncertain ? 'yes' : 'no'}',
  ];
  final extra = [
    if (causes is List && causes.isNotEmpty)
      'causes: ${causes.map((cause) => '$cause').join('; ')}',
    if (cleanup is List && cleanup.isNotEmpty)
      'cleanup: ${cleanup.map((error) => '$error').join('; ')}',
  ];
  return [
    message.isEmpty ? name : '$name: $message',
    '(${details.join(', ')})',
    ...extra,
  ].join(' ');
}
