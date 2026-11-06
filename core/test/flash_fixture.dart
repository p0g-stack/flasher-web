import 'package:flasher_web_core/flasher_web_core.dart';

const testBoot = <String>[
  'boot',
  'dtbo',
  'init_boot',
  'modem',
  'recovery',
  'vbmeta',
  'vbmeta_system',
  'vbmeta_vendor',
  'vendor_boot',
];

const testBaselineLogical = <String>[
  'my_bigball',
  'my_carrier',
  'my_engineering',
  'my_heytap',
  'my_manifest',
  'my_product',
  'my_region',
  'my_stock',
  'odm',
  'product',
  'system',
  'system_dlkm',
  'system_ext',
  'vendor',
  'vendor_dlkm',
  'my_company',
  'my_preload',
];

Selection selectionOf(
  String dev, {
  String kind = 'Super Flasher',
  String region = 'EU',
}) => Selection(dev: dev, kind: kind, region: region);

/// A package with `build.json`, optional `super.img`, and the named images.
///
/// [otherFiles] are full package-relative paths (`OOS_FILES_HERE/pdp.img`);
/// [omit] removes paths afterwards so a missing-image test stays explicit.
PackageIndex flashPackage({
  required String folder,
  bool superImage = true,
  List<String> boot = testBoot,
  List<String> logical = testBaselineLogical,
  List<String> extras = const [],
  List<String> otherFiles = const [],
  List<String> omit = const [],
}) {
  final entries = <String>[
    'build.json',
    'Platform-Tools/fastboot.exe',
    if (superImage) 'super.img',
    for (final partition in boot) '$folder/$partition.img',
    for (final partition in logical) '$folder/$partition.img',
    for (final partition in extras) '$folder/$partition.img',
    ...otherFiles,
  ]..removeWhere(omit.contains);
  return PackageIndex.fromEntries(entries);
}

/// Answers for the product check, plus [answers] for prompts.
Map<String, String> answersFor(
  String dev, [
  Map<String, String> answers = const {},
]) => {
  'product': dev == '13' ? 'sun' : 'test-$dev',
  ...answers,
};

List<Flash> flashes(FlashPlan plan) => [
  for (final step in plan.executionSteps)
    if (step is Flash) step,
];

List<String> flashPartitions(FlashPlan plan) => [
  for (final flash in flashes(plan)) flash.partition,
];

List<FlashStep> execution(FlashPlan plan) => plan.executionSteps;

int indexOfFlash(List<FlashStep> steps, String partition) => steps.indexWhere(
  (step) => step is Flash && step.partition == partition,
);

T singleStep<T extends FlashStep>(FlashPlan plan) =>
    plan.executionSteps.whereType<T>().single;

Prompt promptOf(FlashPlan plan, String id) =>
    plan.steps.whereType<Prompt>().singleWhere((prompt) => prompt.id == id);
