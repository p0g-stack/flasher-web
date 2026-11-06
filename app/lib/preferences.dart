/// The setup choices remembered between visits, like upstream's
/// `settings.json` (`save_preferences`).
final class SetupPreferences {
  const SetupPreferences({
    this.device,
    this.kind,
    this.region,
    this.zipOutput = true,
    this.vulnerableAbl,
  });

  factory SetupPreferences.fromJson(Map<String, Object?> json) =>
      SetupPreferences(
        device: json['device'] as String?,
        kind: json['kind'] as String?,
        region: json['region'] as String?,
        zipOutput: json['zip_output'] is bool
            ? json['zip_output']! as bool
            : true,
        vulnerableAbl: json['vulnerable_abl'] as bool?,
      );

  final String? device;
  final String? kind;
  final String? region;

  /// `ZIP build` is checked on first launch, as upstream does.
  final bool zipOutput;

  /// Kept for parity with upstream's saved values; the choice is deliberately
  /// not restored, so step 4 always asks for an X9U build.
  final bool? vulnerableAbl;

  Map<String, Object?> toJson() => {
    if (device != null) 'device': device,
    if (kind != null) 'kind': kind,
    if (region != null) 'region': region,
    'zip_output': zipOutput,
    if (vulnerableAbl != null) 'vulnerable_abl': vulnerableAbl,
  };

  SetupPreferences copyWith({
    String? device,
    String? kind,
    String? region,
    bool? zipOutput,
    bool? vulnerableAbl,
  }) => SetupPreferences(
    device: device ?? this.device,
    kind: kind ?? this.kind,
    region: region ?? this.region,
    zipOutput: zipOutput ?? this.zipOutput,
    vulnerableAbl: vulnerableAbl ?? this.vulnerableAbl,
  );
}
