/// Turns a flasher package and a selection into an ordered [FlashPlan].
///
/// The order and the image folders come from the pinned upstream launchers in
/// `Flasher_Builder/flasher_scripts/<dev>/<cos|oos>/<super|regional>/`. The
/// launchers mostly run one fixed sequence; the family table below records
/// which template has which sequence. Planning never touches a device: it
/// opens no transport, writes nothing, and stops before any write when a
/// mandatory image is missing.
///
/// Owner decisions applied on top of the scripts:
/// - the connected product is checked against the selected device before the
///   first write;
/// - every write names its destination, including an explicit `_a`/`_b`, and
///   `--slot=all` expands to both suffixes;
/// - the plan stops at the first failure (executor rule) and never resends an
///   uncertain write;
/// - verification follows every reboot back into fastbootd;
/// - wiping stays manual on the phone. The plan only instructs, because no
///   launcher sends a wipe command.
///
/// Where a launcher flashes an unsuffixed logical partition, the plan writes
/// to `_a`: the launchers select slot A later, and the slot active at that
/// moment is device state the plan cannot know. Choosing `_a` makes the
/// destination explicit and matches the slot the plan activates. This differs
/// from the launcher only when the phone's current slot was B before the run;
/// the scripts themselves have the same ambiguity.
library;

import '../upstream/tables.dart';
import 'identity.dart';
import 'model.dart';
import 'package_index.dart';

/// The upstream launcher family a selection belongs to.
enum FlashFamily {
  /// Older batch templates; `.bat` stops only on `choice` and otherwise
  /// continues after a failed flash.
  legacyBatch,

  /// 15/15R/15T/Ace6T templates: a second `reboot fastboot` and a wipe
  /// question regardless of `super.img`.
  newer,

  /// The `.sh` counterparts of tablet/Ace6 OOS super templates. Step order
  /// matches [legacyBatch]; shell error and answer handling differ.
  legacyShell,

  /// X9U COS: existence-guarded two-pass logical reconstruction and an ABL
  /// choice.
  x9u,

  /// NEO8 COS super: existence-guarded boot list, no logical reconstruction.
  neo8,
}

const _superImage = 'super.img';

const _bootPartitions = <String>[
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

const _neo8SuperParts = <String>[
  'my_bigball',
  'my_carrier',
  'my_company',
  'my_engineering',
  'my_heytap',
  'my_manifest',
  'my_preload',
  'my_product',
  'my_region',
  'my_stock',
  'odm',
  'product',
  'system',
  'system_dlkm',
  'system_dlkm_gki',
  'system_dlkm_oki',
  'system_ext',
  'vendor',
  'vendor_dlkm',
];

/// Template membership from the launcher inventory.
///
/// Keys are `<dev>|<subtree>|<super|regional>`; the subtree comes from
/// `device_layout.coloros` (`X9U` and CN use `cos`).
const _legacyBatchKeys = <String>{
  '13|cos|super',
  '13|cos|regional',
  '13|oos|super',
  '13|oos|regional',
  '13R|cos|super',
  '13R|cos|regional',
  '13R|oos|super',
  '13R|oos|regional',
  '13S|oos|super',
  '13S|oos|regional',
  '13T|cos|super',
  '13T|oos|super',
  'Ace5|cos|super',
  'Ace5|cos|regional',
  'Ace5|oos|super',
  'Ace5Pro|cos|super',
  'Ace5Pro|cos|regional',
  'Ace6|cos|super',
  'GT7Pro|cos|super',
  'GT7Pro|oos|super',
  'Pad2Pro|cos|super',
  'Pad3Pro|cos|super',
};

const _legacyShellKeys = <String>{
  'Ace6|oos|super',
  'Pad2Pro|oos|super',
  'Pad3|oos|super',
  'Pad3Pro|oos|super',
};

const _newerKeys = <String>{
  '15|oos|super',
  '15|oos|regional',
  '15|cos|super',
  '15R|oos|super',
  '15R|oos|regional',
  '15T|cos|super',
  'Ace6T|oos|super',
  'Ace6T|cos|super',
};

const _x9uKeys = <String>{'X9U|cos|super', 'X9U|cos|regional'};

const _neo8Keys = <String>{'NEO8|cos|super'};

/// Maps a selection to its launcher family. Unknown combinations are an
/// error: the package cannot tell which order a missing template would use.
FlashFamily flashFamily(Selection selection) {
  final key =
      '${selection.dev}|${selection.subtree}|'
      '${selection.kind.contains('Super') ? 'super' : 'regional'}';
  if (_legacyBatchKeys.contains(key)) return FlashFamily.legacyBatch;
  if (_legacyShellKeys.contains(key)) return FlashFamily.legacyShell;
  if (_newerKeys.contains(key)) return FlashFamily.newer;
  if (_x9uKeys.contains(key)) return FlashFamily.x9u;
  if (_neo8Keys.contains(key)) return FlashFamily.neo8;
  throw FlashPlanException(
    'No flasher family for ${selection.dev} / ${selection.kind} / '
    '${selection.region} (${selection.template}).',
  );
}

/// Builds the plan for [package] and [selection].
///
/// [answers] maps a prompt id (`bloat`, `root`, `abl`, `wipe`) to one of its
/// choice keys. An omitted answer uses the launcher's default; when the
/// launcher has no default the prompt stays unanswered and
/// [FlashPlan.executionSteps] refuses to run. `product` is the only
/// non-prompt key: it supplies the expected `getvar product` when the device
/// table marks it unknown, and must agree with the table when it is known.
///
/// Every image the selected branches flash must exist in [package]; the
/// launchers' own existence guards (X9U's logical list, NEO8's boot list) are
/// reproduced, and nothing else is skipped.
FlashPlan planFlash(
  PackageIndex package,
  Selection selection,
  Map<String, String> answers,
) {
  final family = flashFamily(selection);
  final expectation = resolveDeviceExpectation(selection.dev, answers);
  final usedAnswers = <String>{
    if (answers.containsKey('product')) 'product',
  };
  final folder = selection.imageFolder;
  final hasSuper = package.has(_superImage);
  final isSuper = selection.kind.contains('Super');
  final dev = selection.dev;

  if (family == FlashFamily.neo8) {
    if (!hasSuper) {
      throw const FlashPlanException(
        'Incomplete NEO8 package: super.img is required.',
      );
    }
    if (!package.has('$folder/boot.img')) {
      throw FlashPlanException(
        'Incomplete NEO8 package: $folder/boot.img is required.',
      );
    }
  }
  if (family == FlashFamily.x9u) {
    if (isSuper && !hasSuper) {
      throw const FlashPlanException(
        'Incomplete package: an X9U super flasher requires super.img.',
      );
    }
    if (!package.has('$folder/boot.img')) {
      throw FlashPlanException('Incomplete package: $folder/boot.img is missing.');
    }
  }

  final logical = family == FlashFamily.neo8
      ? const <String>[]
      : _logicalList(family, dev);
  final excluded = family == FlashFamily.neo8
      ? {..._bootPartitions, ..._neo8SuperParts}
      : {
          ..._bootPartitions,
          ...logical,
          if (family == FlashFamily.x9u) 'abl',
        };

  Prompt prompt({
    required String id,
    required String question,
    required Map<String, List<FlashStep>> choices,
    required String? defaultChoice,
  }) {
    final answer = answers[id];
    if (answer != null) {
      if (!choices.containsKey(answer)) {
        throw FlashPlanException(
          'The answer "$answer" is not valid for "$id"; expected one of '
          '${choices.keys.join(', ')}.',
        );
      }
      usedAnswers.add(id);
    }
    return Prompt(
      id: id,
      question: question,
      choices: choices,
      defaultChoice: defaultChoice,
      answer: answer,
    );
  }

  Prompt bloatPrompt(String? defaultChoice) => prompt(
    id: 'bloat',
    question: 'Do you want full Chinese bloat?',
    choices: {
      'keep-bloat': const <FlashStep>[],
      'debloat': [
        ..._prepare('my_preload'),
        const Flash('my_preload_a', 'OOS_FILES_HERE/my_preload.img'),
      ],
    },
    defaultChoice: defaultChoice,
  );

  Prompt rootPrompt() => prompt(
    id: 'root',
    question:
        'Are you going to root your $dev? '
        '(prepare for root, or flash the signal/region images)',
    choices: {
      'prepare-root': const <FlashStep>[],
      'flash-signal': _signalSteps(selection),
    },
    defaultChoice: null,
  );

  Prompt ablPrompt() => prompt(
    id: 'abl',
    question: 'Do you want to keep the current ABL?',
    choices: {
      'keep-abl': const <FlashStep>[],
      'flash-abl': [
        Flash('abl_a', '$folder/abl.img'),
        Flash('abl_b', '$folder/abl.img'),
      ],
    },
    defaultChoice: 'keep-abl',
  );

  Prompt wipePrompt({
    required String question,
    required String? defaultChoice,
  }) => prompt(
    id: 'wipe',
    question: question,
    choices: {
      'reboot': const <FlashStep>[RebootTo(FlashMode.android)],
      'wipe': const <FlashStep>[
        Instruct(
          'On the phone, tap Format Data and confirm. The phone reboots into '
          'Android by itself; the host sends no wipe command.',
        ),
      ],
    },
    defaultChoice: defaultChoice,
  );

  final steps = <FlashStep>[
    const RequireMode(FlashMode.bootloader),
    GetvarCheck('product', expectation.product),
    if (family == FlashFamily.neo8)
      const Instruct(
        'Use only with an unlocked Realme NEO8 on matching CN firmware. '
        'Connect it in bootloader fastboot before continuing.',
      ),
    ..._bootSteps(
      package: package,
      folder: folder,
      guardMissing: family == FlashFamily.neo8,
    ),
    if (hasSuper) const Flash('super', _superImage, sparse: true),
    const RebootTo(FlashMode.fastbootd),
    const RequireMode(FlashMode.fastbootd),
    const Instruct(
      'On the phone, select English in fastbootd; continue when it is ready.',
    ),
    ..._extraSteps(package: package, folder: folder, excluded: excluded),
  ];

  if (!hasSuper) {
    steps.addAll(
      family == FlashFamily.x9u
          ? _x9uLogicalSteps(
              package: package,
              folder: folder,
              logical: logical,
            )
          // Both the older batch templates and their shell counterparts flash
          // these unsuffixed; see the library comment for the `_a` mapping.
          : _logicalSteps(folder: folder, logical: logical),
    );
  }

  if (family == FlashFamily.newer) {
    // 15 COS asks about bloat before `--set-active=a`.
    if (selection.coloros) steps.add(bloatPrompt('debloat'));
    steps.addAll(const [SetActive(FlashSlot.a), RebootTo(FlashMode.fastbootd)]);
    steps.add(const RequireMode(FlashMode.fastbootd));
    steps.add(
      wipePrompt(question: 'Do you want to wipe data?', defaultChoice: 'reboot'),
    );
  } else if (family == FlashFamily.x9u) {
    steps.add(ablPrompt());
    steps.addAll(const [SetActive(FlashSlot.a), RebootTo(FlashMode.fastbootd)]);
    steps.add(const RequireMode(FlashMode.fastbootd));
    steps.add(
      wipePrompt(question: 'Do you want to wipe data?', defaultChoice: 'reboot'),
    );
  } else if (family == FlashFamily.neo8) {
    steps.add(const SetActive(FlashSlot.a));
    steps.add(
      wipePrompt(
        question: 'Format data on the phone before booting?',
        defaultChoice: 'reboot',
      ),
    );
  } else {
    // Older batch family and its shell counterparts.
    steps.add(const SetActive(FlashSlot.a));
    if (selection.coloros) {
      steps.add(bloatPrompt(family == FlashFamily.legacyShell ? 'debloat' : null));
    }
    if (!hasSuper) {
      steps.add(
        wipePrompt(
          question: 'Do you want to wipe data?',
          defaultChoice: family == FlashFamily.legacyShell ? 'reboot' : null,
        ),
      );
    } else {
      if (_hasSignalPrompt(selection)) steps.add(rootPrompt());
      steps.add(
        wipePrompt(
          question:
              'Are you flashing from ColorOS or do you want to wipe data?',
          // The shell's `[nN]*` match reboots; every other answer, including
          // nothing, means a manual wipe. The batch `choice` has no default.
          defaultChoice: family == FlashFamily.legacyShell ? 'wipe' : null,
        ),
      );
    }
  }

  for (final key in answers.keys) {
    if (!usedAnswers.contains(key)) {
      throw FlashPlanException('No step in this plan uses the answer "$key".');
    }
  }
  _preflight(package, steps);
  return FlashPlan(
    identity: expectation,
    family: family.name,
    template: selection.template,
    steps: steps,
  );
}

/// The exact logical list of a family, in launcher order.
List<String> _logicalList(FlashFamily family, String dev) {
  const before = <String>[
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
  ];
  const after = <String>[
    'system_ext',
    'vendor',
    'vendor_dlkm',
    'my_company',
    'my_preload',
  ];
  final dlkm = switch (family) {
    FlashFamily.legacyBatch || FlashFamily.legacyShell => [
      if (dev == 'Ace6') 'system_dlkm_gki',
      if (dev == 'Ace6' || dev == 'Pad3Pro') 'system_dlkm_oki',
    ],
    FlashFamily.newer => ['system_dlkm_oki'],
    FlashFamily.x9u => ['system_dlkm_oki', 'system_dlkm_gki'],
    FlashFamily.neo8 => const <String>[],
  };
  return [...before, ...dlkm, ...after];
}

/// NEO8 skips boot images that are not in the package; every other family
/// only skips where its launcher tests the file (X9U's logical list).
List<FlashStep> _bootSteps({
  required PackageIndex package,
  required String folder,
  required bool guardMissing,
}) {
  final steps = <FlashStep>[];
  for (final partition in _bootPartitions) {
    final image = '$folder/$partition.img';
    if (guardMissing && !package.has(image)) continue;
    steps.add(Flash('${partition}_a', image));
    steps.add(Flash('${partition}_b', image));
  }
  return steps;
}

/// `for D/*.img` with exact-name exclusions, then `flash --slot=all`.
List<FlashStep> _extraSteps({
  required PackageIndex package,
  required String folder,
  required Set<String> excluded,
}) => [
  for (final image in package.imagesIn(folder))
    if (!excluded.contains(image.stem)) ...[
      Flash('${image.stem}_a', image.path),
      Flash('${image.stem}_b', image.path),
    ],
];

List<FlashStep> _prepare(String partition) => [
  DeleteLogical('${partition}_a'),
  DeleteLogical('${partition}_b'),
  DeleteLogical('${partition}_a-cow'),
  DeleteLogical('${partition}_b-cow'),
  CreateLogical('${partition}_a', 1),
  CreateLogical('${partition}_b', 1),
];

/// The older no-super branch: prepare and flash each listed partition.
List<FlashStep> _logicalSteps({
  required String folder,
  required List<String> logical,
}) => [
  for (final partition in logical) ...[
    ..._prepare(partition),
    Flash('${partition}_a', '$folder/$partition.img'),
  ],
];

/// X9U prepares every present partition first, then flashes; absent images
/// are skipped, exactly like the launcher's two `-f` passes.
List<FlashStep> _x9uLogicalSteps({
  required PackageIndex package,
  required String folder,
  required List<String> logical,
}) {
  final present = [
    for (final partition in logical)
      if (package.imageExists(folder, partition)) partition,
  ];
  return [
    for (final partition in present) ..._prepare(partition),
    for (final partition in present)
      Flash('${partition}_a', '$folder/$partition.img'),
  ];
}

/// The OOS "prepare for root?" branch, with its COS signal images.
///
/// Only the 13 and GT7Pro super launchers name both slots. The 13 and 13S
/// regional launchers and the 13T super launcher flash unsuffixed, which the
/// plan writes to `_a` (see the library comment).
List<FlashStep> _signalSteps(Selection selection) {
  const stan = 'COS_FILES_HERE/oplusstanvbk.img';
  const region = 'COS_FILES_HERE/my_region.img';
  final dev = selection.dev;
  final isSuper = selection.kind.contains('Super');
  if (isSuper && (dev == '13' || dev == 'GT7Pro')) {
    return const [
      Flash('oplusstanvbk_a', stan),
      Flash('oplusstanvbk_b', stan),
      Flash('my_region_a', region),
      Flash('my_region_b', region),
    ];
  }
  if (dev == '13T') {
    return [
      const Flash('oplusstanvbk_a', stan),
      const Flash('my_region_a', region),
      ..._prepare('odm'),
      const Flash('odm_a', 'COS_FILES_HERE/odm.img'),
    ];
  }
  return const [Flash('oplusstanvbk_a', stan), Flash('my_region_a', region)];
}

/// Whether this template has the OOS root/signal prompt. Only these launchers
/// ask it, and only when `super.img` exists.
bool _hasSignalPrompt(Selection selection) {
  if (selection.subtree != 'oos') return false;
  final isSuper = selection.kind.contains('Super');
  return switch (selection.dev) {
    '13' => true,
    '13T' => true,
    'GT7Pro' => true,
    '13S' => !isSuper,
    _ => false,
  };
}

/// Fails before any write when a selected branch needs an absent image.
void _preflight(PackageIndex package, Iterable<FlashStep> steps) {
  for (final step in steps) {
    if (step is Flash && !package.has(step.image)) {
      throw FlashPlanException(
        'The package is missing ${step.image}, needed to flash '
        '${step.partition}.',
      );
    }
    if (step is Prompt) {
      final selected = step.selectedSteps;
      if (selected != null) _preflight(package, selected);
    }
  }
}
