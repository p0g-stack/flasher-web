/// Native stores have explicit paths. A different spelling needs a new plan.
Future<bool> sameFlashStore(
  Map<String, Object?> left,
  Map<String, Object?> right,
) async =>
    left['kind'] == right['kind'] &&
    left['path'] == right['path'] &&
    left['handle'] == right['handle'];
