/// Declarative flashing only: no transport, retries, or device writes.
library;

/// A fastboot mode, identified by the device's own getvar answers.
///
/// `superFastboot` is CANOE-BDS's bootloader replacement. It answers
/// `getvar:canoe-bds` and may also say `is-userspace:no`, so probing
/// `is-userspace` first would mistake it for the normal bootloader.
enum FlashMode { bootloader, fastbootd, superFastboot, android }

enum FlashSlot { a, b }

final class FlashPlanException implements Exception {
  const FlashPlanException(this.message);
  final String message;
  @override
  String toString() => 'FlashPlanException: $message';
}

/// A package, device or protocol error that is not a planning error.
final class FlashException implements Exception {
  const FlashException(this.message, {this.uncertain = false});
  final String message;

  /// True when a write may have reached the device.
  final bool uncertain;

  /// Structured failure data for services, receipts and the UI. Blame is the
  /// user because the plan is the app's own domain check; the message stays
  /// the original text, never an encoded packet.
  Map<String, Object?> failure({String stage = 'execute', String stack = ''}) =>
      {
        'blame': 'user',
        'name': 'FlashException',
        'message': message,
        'stage': stage,
        'uncertain': uncertain,
        'stack': stack,
        'causes': const <String>[],
        'cleanupErrors': const <String>[],
      };

  @override
  String toString() => 'FlashException: $message';
}

sealed class FlashStep {
  const FlashStep();
  String get text;
}

final class RequireMode extends FlashStep {
  const RequireMode(this.mode);
  final FlashMode mode;
  @override
  String get text => 'Verify device mode is ${mode.name}';
}

final class GetvarCheck extends FlashStep {
  const GetvarCheck(this.name, this.expected);
  final String name;
  final String expected;
  @override
  String get text => 'Require getvar $name = $expected';
}

final class Flash extends FlashStep {
  const Flash(this.partition, this.image, {this.sparse});
  final String partition;

  /// Relative to the indexed package root, never a host filesystem path.
  final String image;

  /// True for the generated super; null means inspect the image header.
  final bool? sparse;
  @override
  String get text => 'Flash $partition from $image';
}

final class DeleteLogical extends FlashStep {
  const DeleteLogical(this.name);
  final String name;
  @override
  String get text => 'Delete logical partition $name';
}

final class CreateLogical extends FlashStep {
  const CreateLogical(this.name, this.size);
  final String name;
  final int size;
  @override
  String get text => 'Create logical partition $name ($size bytes)';
}

final class RebootTo extends FlashStep {
  const RebootTo(this.mode);
  final FlashMode mode;
  @override
  String get text => 'Reboot to ${mode.name}';
}

final class SetActive extends FlashStep {
  const SetActive(this.slot);
  final FlashSlot slot;
  @override
  String get text => 'Set active slot ${slot.name}';
}

final class Instruct extends FlashStep {
  const Instruct(this.text);
  @override
  final String text;
}

/// Answers select substeps in place, never reorder them. A null default means
/// upstream's batch `choice` has no default and requires an explicit answer.
final class Prompt extends FlashStep {
  Prompt({
    required this.id,
    required this.question,
    required Map<String, List<FlashStep>> choices,
    required this.defaultChoice,
    required this.answer,
  }) : choices = Map<String, List<FlashStep>>.unmodifiable({
         for (final e in choices.entries)
           e.key: List<FlashStep>.unmodifiable(e.value),
       });
  final String id;
  final String question;
  final Map<String, List<FlashStep>> choices;
  final String? defaultChoice;
  final String? answer;
  String? get selectedChoice => answer ?? defaultChoice;
  List<FlashStep>? get selectedSteps => choices[selectedChoice];
  @override
  String get text =>
      '$question (choices: ${choices.keys.join('/')}; '
      'default: ${defaultChoice ?? 'explicit answer required'}; '
      'selected: ${selectedChoice ?? 'unanswered'})';
}

final class DeviceExpectation {
  const DeviceExpectation({
    required this.dev,
    required this.product,
    required this.confidence,
    this.overrideText,
  });
  final String dev;
  final String product;
  final String confidence;
  final String? overrideText;
}

/// Executors MUST stop at the first failure, pin the confirmed serial across
/// reconnects, and never resend an uncertain write. Every reboot back into
/// fastbootd is followed by an explicit mode check. The final reboot leaves
/// fastboot, so it carries no fastboot mode check.
final class FlashPlan {
  FlashPlan({
    required this.identity,
    required this.family,
    required this.template,
    required List<FlashStep> steps,
  }) : steps = List<FlashStep>.unmodifiable(steps);
  final DeviceExpectation identity;
  final String family;
  final String template;
  final List<FlashStep> steps;

  bool get isResolved {
    bool resolved(Iterable<FlashStep> steps) => steps.every(
      (step) =>
          step is! Prompt ||
          (step.selectedSteps != null && resolved(step.selectedSteps!)),
    );
    return resolved(steps);
  }

  /// Only a fully answered, preflighted plan may be executed.
  List<FlashStep> get executionSteps {
    final result = <FlashStep>[];
    void expand(Iterable<FlashStep> steps) {
      for (final step in steps) {
        if (step is Prompt) {
          final selected = step.selectedSteps;
          if (selected == null) {
            throw FlashPlanException('Answer required: ${step.id}');
          }
          expand(selected);
        } else {
          result.add(step);
        }
      }
    }

    expand(steps);
    return List<FlashStep>.unmodifiable(result);
  }

  /// The transport request must bind this same nonempty serial at apply time.
  List<String> confirmationText(String serial) {
    if (serial.trim().isEmpty) {
      throw const FlashPlanException('A device serial is required.');
    }
    return List<String>.unmodifiable([
      'Flash ${identity.dev}, serial $serial, product ${identity.product}',
      if (identity.overrideText != null) identity.overrideText!,
      for (final step in steps) step.text,
    ]);
  }
}
