/// The setup choices remembered between visits, like upstream's
/// `settings.json` (`save_preferences`).
final class SetupPreferences {
  const SetupPreferences({
    this.device,
    this.kind,
    this.region,
    this.vulnerableAbl,
  });

  factory SetupPreferences.fromJson(Map<String, Object?> json) =>
      SetupPreferences(
        device: json['device'] as String?,
        kind: json['kind'] as String?,
        region: json['region'] as String?,
        vulnerableAbl: json['vulnerable_abl'] as bool?,
      );

  final String? device;
  final String? kind;
  final String? region;

  /// Kept for parity with upstream's saved values; the choice is deliberately
  /// not restored, so step 4 always asks for an X9U flash.
  final bool? vulnerableAbl;

  Map<String, Object?> toJson() => {
    if (device != null) 'device': device,
    if (kind != null) 'kind': kind,
    if (region != null) 'region': region,
    if (vulnerableAbl != null) 'vulnerable_abl': vulnerableAbl,
  };

  SetupPreferences copyWith({
    String? device,
    String? kind,
    String? region,
    bool? vulnerableAbl,
  }) => SetupPreferences(
    device: device ?? this.device,
    kind: kind ?? this.kind,
    region: region ?? this.region,
    vulnerableAbl: vulnerableAbl ?? this.vulnerableAbl,
  );
}
