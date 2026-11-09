import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'device_sheet.dart';
import 'flash_controller.dart';

/// Flash a finished job: device, read-only preparation, explicit choices,
/// exact confirmation, streamed execution and the persisted receipt.
class FlashPage extends StatefulWidget {
  const FlashPage({super.key, required this.controller, required this.onBack});

  final FlashController controller;
  final VoidCallback onBack;

  @override
  State<FlashPage> createState() => _FlashPageState();
}

class _FlashPageState extends State<FlashPage> {
  final _product = TextEditingController();
  final _productFocus = FocusNode();
  final _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _product.text = widget.controller.answers['product'] ?? '';
    _product.addListener(_onProductChanged);
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _product.removeListener(_onProductChanged);
    _product.dispose();
    _productFocus.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  void _onProductChanged() {
    widget.controller.setProductOverride(_product.text);
  }

  void _onControllerChanged() {
    final answer = widget.controller.answers['product'] ?? '';
    if (!_productFocus.hasFocus && _product.text != answer) {
      _product.text = answer;
    }
    if (_logScroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_logScroll.hasClients) return;
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      });
    }
  }

  Future<void> _openDeviceSheet() async {
    final device = await showFastbootDeviceSheet(
      context,
      api: widget.controller.api,
      bridge: widget.controller.bridge,
    );
    if (!mounted || device == null) return;
    widget.controller.selectDevice(device);
  }

  Future<void> _flash() async {
    await widget.controller.flash();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusCard(controller: controller),
              const SizedBox(height: 16),
              _TargetCard(controller: controller),
              const SizedBox(height: 16),
              _DeviceCard(controller: controller, onChoose: _openDeviceSheet),
              if (controller.serial != null) ...[
                const SizedBox(height: 16),
                _PreparationCard(
                  controller: controller,
                  product: _product,
                  productFocus: _productFocus,
                ),
              ],
              if (controller.planSteps.isNotEmpty ||
                  (controller.prepared?.steps.isNotEmpty ?? false)) ...[
                const SizedBox(height: 16),
                _PlanCard(controller: controller),
              ],
              if (controller.prepared != null) ...[
                const SizedBox(height: 16),
                _ConfirmationCard(controller: controller, onFlash: _flash),
              ],
              if (controller.running ||
                  controller.terminal ||
                  controller.log.isNotEmpty) ...[
                const SizedBox(height: 16),
                _ExecutionCard(controller: controller, logScroll: _logScroll),
              ],
              if (controller.terminal) ...[
                const SizedBox(height: 16),
                _ResultCard(controller: controller),
              ],
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: const ValueKey('backFromFlash'),
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back, size: 18),
                label: const Text('Back to setup'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller});

  final FlashController controller;

  String get _title => switch (controller.phase) {
    FlashPhase.idle =>
      controller.serial == null ? 'Choose a fastboot device' : 'Ready to flash',
    FlashPhase.preparing => 'Preparing the plan (read-only)',
    FlashPhase.ready =>
      controller.ready
          ? 'Plan resolved · confirm the exact device'
          : 'The plan still needs answers',
    FlashPhase.running =>
      controller.stepTitle.isEmpty ? 'Flashing' : controller.stepTitle,
    FlashPhase.succeeded => 'Flash complete',
    FlashPhase.failed => 'Flash failed · stopped at the first error',
    FlashPhase.uncertain => 'Flash uncertain · inspect the phone',
    FlashPhase.cancelled => 'Flash cancelled · not rolled back',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = controller.totalSteps;
    final value = total <= 0
        ? null
        : (controller.stepIndex / total).clamp(0.0, 1.0);
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _title,
                  key: const ValueKey('flashStatus'),
                  style: theme.textTheme.titleMedium,
                ),
              ),
              _PhaseBadge(phase: controller.phase),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: switch (controller.phase) {
              FlashPhase.succeeded ||
              FlashPhase.failed ||
              FlashPhase.uncertain ||
              FlashPhase.cancelled => 1,
              FlashPhase.running => controller.totalSteps == 0 ? null : value,
              _ => 0,
            },
            minHeight: 5,
          ),
          if (controller.running) ...[
            const SizedBox(height: 8),
            Text(
              total > 0
                  ? 'Step ${controller.stepIndex} of $total'
                  : 'Starting the first step…',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (!controller.writesSupported) ...[
            const SizedBox(height: 8),
            const HintText(
              'This browser context reports no WebUSB support (usb.web). '
              'Open the app in a current Chromium browser over HTTPS or '
              'localhost; flashing stays disabled.',
              error: true,
            ),
          ],
        ],
      ),
    );
  }
}

class _PhaseBadge extends StatelessWidget {
  const _PhaseBadge({required this.phase});

  final FlashPhase phase;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = switch (phase) {
      FlashPhase.succeeded => ('DONE', theme.colorScheme.primary),
      FlashPhase.failed => ('FAILED', theme.colorScheme.error),
      FlashPhase.uncertain => ('UNCERTAIN', theme.colorScheme.error),
      FlashPhase.cancelled => ('CANCELLED', theme.colorScheme.outline),
      FlashPhase.running => ('WRITING', theme.colorScheme.tertiary),
      FlashPhase.preparing => ('READ-ONLY', theme.colorScheme.secondary),
      _ => ('NOT STARTED', theme.colorScheme.outline),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.7,
        ),
      ),
    );
  }
}

class _TargetCard extends StatelessWidget {
  const _TargetCard({required this.controller});

  final FlashController controller;

  @override
  Widget build(BuildContext context) {
    final target = controller.target;
    return SectionCard(
      title: 'Package to flash',
      trailing: const Icon(Icons.inventory_2_outlined, size: 20),
      child: Column(
        children: [
          LabeledValue(label: 'Job', value: controller.jobId),
          LabeledValue(label: 'Package', value: target.label),
          LabeledValue(
            label: 'Selection',
            value: '${target.device} · ${target.kind} · ${target.region}',
          ),
          LabeledValue(
            label: 'Store',
            value:
                'OTA read in place · bloat store '
                '${target.virtualBloat['kind'] ?? 'unknown'}',
          ),
        ],
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.controller, required this.onChoose});

  final FlashController controller;
  final Future<void> Function() onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prepared = controller.prepared;
    return SectionCard(
      title: 'Fastboot device',
      trailing: TextButton.icon(
        key: const ValueKey('checkGranted'),
        onPressed: controller.running || controller.devicesLoading
            ? null
            : controller.refreshDevices,
        icon: const Icon(Icons.refresh, size: 16),
        label: const Text('Check granted'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.devicesLoading)
            const LinearProgressIndicator(minHeight: 3)
          else if (controller.serial == null && controller.devicesError != null)
            HintText(controller.devicesError!, error: true)
          else if (controller.serial == null)
            const HintText(
              'No device selected. Choose one through WebUSB, or check devices '
              'this page already has permission for.',
            )
          else ...[
            Text(
              controller.serial!,
              key: const ValueKey('selectedSerial'),
              style: theme.textTheme.titleLarge?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
            if (controller.deviceLabel.isNotEmpty)
              Text(
                controller.deviceLabel,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            if (prepared != null) ...[
              const SizedBox(height: 8),
              LabeledValue(
                label: 'Connected product',
                value: prepared.product.isEmpty ? 'unknown' : prepared.product,
                monospace: true,
              ),
              LabeledValue(
                label: 'Expected product',
                value: prepared.expectedProduct,
                monospace: true,
              ),
              LabeledValue(
                label: 'Actual mode',
                value: prepared.mode,
                monospace: true,
              ),
              if (!prepared.modeOk)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: HintText(
                    'The phone is not in bootloader fastboot. Reboot it there, '
                    'check the device again and prepare a new plan.',
                    error: true,
                  ),
                ),
            ],
          ],
          if (!controller.devicesLoading &&
              controller.devicesError != null &&
              controller.serial != null) ...[
            const SizedBox(height: 8),
            HintText(controller.devicesError!, error: true),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                key: const ValueKey('chooseDevice'),
                onPressed: controller.writesSupported && !controller.running
                    ? onChoose
                    : null,
                icon: const Icon(Icons.usb, size: 18),
                label: const Text('Choose device'),
              ),
              const SizedBox(width: 10),
              if (controller.serial != null && !controller.running)
                OutlinedButton.icon(
                  key: const ValueKey('prepareFlashAgain'),
                  onPressed: controller.preparing ? null : controller.prepare,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Prepare again'),
                ),
            ],
          ),
          if (!controller.pageCanChoose) ...[
            const SizedBox(height: 8),
            const HintText(
              'This page cannot open a WebUSB chooser. Use current Chrome, '
              'Edge or Chromium over HTTPS or localhost.',
              error: true,
            ),
          ],
        ],
      ),
    );
  }
}

class _PreparationCard extends StatelessWidget {
  const _PreparationCard({
    required this.controller,
    required this.product,
    required this.productFocus,
  });

  final FlashController controller;
  final TextEditingController product;
  final FocusNode productFocus;

  @override
  Widget build(BuildContext context) {
    final prepared = controller.prepared;
    return SectionCard(
      title: 'Answers and product',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.preparing)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(minHeight: 3),
            ),
          if (controller.prepareError != null) ...[
            HintText(
              controller.prepareError!,
              key: const ValueKey('prepareError'),
              error: true,
            ),
            const SizedBox(height: 10),
          ],
          if (controller.productRequired) ...[
            const HintText(
              'The expected fastboot product is not in the device table. Read '
              'it on the phone with `fastboot getvar product` and enter that '
              'exact value. Preparation refuses to guess.',
              key: ValueKey('productOverrideRequired'),
              error: true,
            ),
            const SizedBox(height: 8),
          ],
          TextField(
            key: const ValueKey('productOverride'),
            controller: product,
            focusNode: productFocus,
            enabled: !controller.running,
            decoration: InputDecoration(
              labelText: 'Product override',
              helperText:
                  'Only needed when preparation reports the expected product '
                  'is unconfirmed.',
              helperMaxLines: 2,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          if (prepared != null) ...[
            const SizedBox(height: 12),
            if (prepared.prompts.isEmpty)
              const HintText('This plan has no remaining questions.')
            else
              for (final prompt in prepared.prompts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        prompt.question,
                        key: ValueKey('prompt-${prompt.id}'),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final choice in prompt.choices)
                            ChoiceChip(
                              key: ValueKey('answer-${prompt.id}-$choice'),
                              label: Text(choice),
                              selected: controller.answers[prompt.id] == choice,
                              onSelected: controller.running
                                  ? null
                                  : (_) => controller.answerPrompt(
                                      prompt.id,
                                      choice,
                                    ),
                            ),
                        ],
                      ),
                      if (prompt.selected != null &&
                          controller.answers[prompt.id] == null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: HintText(
                            'The plan suggests "${prompt.selected}". It is not '
                            'applied; choose an answer explicitly.',
                          ),
                        ),
                    ],
                  ),
                ),
            if (!controller.answersComplete)
              const HintText(
                'Every question needs an explicit answer before the plan can '
                'resolve and produce a confirmation token.',
                key: ValueKey('answersIncomplete'),
              ),
          ],
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.controller});

  final FlashController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final steps = controller.planSteps.isNotEmpty
        ? controller.planSteps
        : controller.prepared?.steps ?? const <String>[];
    return SectionCard(
      key: const ValueKey('flashPlan'),
      title: 'Ordered plan',
      trailing: HintText(
        controller.prepared?.resolved == true
            ? '${steps.length} steps'
            : 'outline only',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 30,
                    child: Text(
                      '${i + 1}'.padLeft(2, '0'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      steps[i],
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          if (controller.prepared?.resolved != true)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: HintText(
                'This is the plan outline. Answers replace the questions and '
                'produce the complete ordered plan.',
              ),
            ),
          for (final warning
              in controller.prepared?.warnings ?? const <String>[])
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: HintText('Warning: $warning', error: true),
            ),
        ],
      ),
    );
  }
}

class _ConfirmationCard extends StatelessWidget {
  const _ConfirmationCard({required this.controller, required this.onFlash});

  final FlashController controller;
  final Future<void> Function() onFlash;

  @override
  Widget build(BuildContext context) {
    final prepared = controller.prepared!;
    final theme = Theme.of(context);
    return SectionCard(
      key: const ValueKey('flashConfirmation'),
      title: 'Confirm the exact device',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This writes to the phone. Wiping and root installation '
                  'remain manual on the phone.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Serial: ${prepared.serial}',
                  key: const ValueKey('confirmSerialValue'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
                Text(
                  'Product: ${prepared.expectedProduct}',
                  key: const ValueKey('confirmProductValue'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
                Text(
                  'Connected product: ${prepared.product} · mode: '
                  '${prepared.mode}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (prepared.confirmation.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Full confirmation text'),
              children: [
                for (final line in prepared.confirmation)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: SelectableText(
                        line,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
              ],
            ),
          CheckboxListTile(
            key: const ValueKey('confirmFlashDevice'),
            contentPadding: EdgeInsets.zero,
            value: controller.acknowledged,
            onChanged:
                controller.writesSupported &&
                    controller.ready &&
                    !controller.running
                ? (value) => controller.setAcknowledged(value == true)
                : null,
            title: Text(
              'I confirm serial ${prepared.serial} and product '
              '${prepared.expectedProduct}.',
            ),
            subtitle: const Text(
              'Changing the device, job, product or any answer clears this '
              'confirmation and the token.',
            ),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          const SizedBox(height: 4),
          FilledButton.icon(
            key: const ValueKey('startFlash'),
            onPressed: controller.canFlash ? onFlash : null,
            icon: const Icon(Icons.flash_on, size: 18),
            label: const Text('Flash device'),
          ),
          const SizedBox(height: 6),
          HintText(
            controller.blockingReason ?? 'The plan is resolved and confirmed.',
            key: const ValueKey('flashBlocked'),
            error: !controller.canFlash,
          ),
        ],
      ),
    );
  }
}

class _ExecutionCard extends StatelessWidget {
  const _ExecutionCard({required this.controller, required this.logScroll});

  final FlashController controller;
  final ScrollController logScroll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final progress = controller.progress.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return SectionCard(
      title: 'Execution',
      trailing: TextButton.icon(
        key: const ValueKey('saveFlashLog'),
        onPressed: controller.log.isEmpty ? null : controller.saveLog,
        icon: const Icon(Icons.save_alt, size: 16),
        label: const Text('Save log'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.waiting != null)
            Container(
              key: const ValueKey('flashWaiting'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'The phone must return in '
                    '${controller.waitingMode ?? 'fastboot'}.',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  HintText(
                    controller.waitingText ??
                        'Grant serial ${controller.waitingSerial} again in the '
                            'USB chooser. Another phone is refused.',
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    key: const ValueKey('regrantDevice'),
                    onPressed: controller.regranting
                        ? null
                        : controller.regrantDevice,
                    icon: const Icon(Icons.usb, size: 18),
                    label: const Text('Grant the same device again'),
                  ),
                  if (controller.regrantMessage != null) ...[
                    const SizedBox(height: 6),
                    HintText(
                      controller.regrantMessage!,
                      key: const ValueKey('regrantMessage'),
                      error: !controller.regrantMessage!.contains('granted'),
                    ),
                  ],
                ],
              ),
            ),
          if (progress.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final entry in progress)
              ByteProgress(
                label: entry.key,
                done: entry.value.done,
                total: entry.value.total,
              ),
          ],
          if (controller.running) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    controller.stepTitle.isEmpty
                        ? 'Starting…'
                        : '${controller.stepIndex}/${controller.totalSteps}  '
                              '${controller.stepTitle}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('cancelFlash'),
                  onPressed: controller.cancel,
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text('Cancel'),
                ),
              ],
            ),
            const HintText(
              'Cancel stops future commands. It is not a rollback; a write '
              'already in flight may leave the phone partially written.',
              error: true,
            ),
          ],
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('flashLog'),
            height: 260,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF0B1017) : const Color(0xFF111827),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Scrollbar(
              controller: logScroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: logScroll,
                child: SelectableText(
                  controller.log.isEmpty
                      ? 'No commands yet. Preparation is read-only; commands '
                            'appear here once the flash starts.'
                      : controller.logText,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.45,
                    color: Color(0xFFD7E3F4),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.controller});

  final FlashController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final receipt = controller.receipt;
    final status = controller.phase;
    final failure = receipt?['failure'] is Map
        ? Map<String, Object?>.from(receipt!['failure']! as Map)
        : null;
    final verification = receipt?['verification'] is Map
        ? Map<String, Object?>.from(receipt!['verification']! as Map)
        : null;
    final steps = receipt?['steps'] is List
        ? [
            for (final step in receipt!['steps']! as List)
              if (step is Map) Map<String, Object?>.from(step),
          ]
        : const <Map<String, Object?>>[];
    final warnings = receipt?['warnings'] is List
        ? [
            for (final warning in receipt!['warnings']! as List)
              if (warning is String) warning,
          ]
        : const <String>[];
    final cleanup = receipt?['cleanupErrors'] is List
        ? [
            for (final error in receipt!['cleanupErrors']! as List)
              if (error is String) error,
          ]
        : const <String>[];
    return SectionCard(
      key: const ValueKey('flashReceipt'),
      title: 'Receipt',
      trailing: Icon(
        switch (status) {
          FlashPhase.succeeded => Icons.check_circle,
          FlashPhase.failed || FlashPhase.uncertain => Icons.error_outline,
          _ => Icons.info_outline,
        },
        color: switch (status) {
          FlashPhase.succeeded => theme.colorScheme.primary,
          FlashPhase.failed || FlashPhase.uncertain => theme.colorScheme.error,
          _ => theme.colorScheme.outline,
        },
        size: 20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.guidance != null) ...[
            HintText(
              controller.guidance!,
              key: const ValueKey('flashGuidance'),
              error:
                  status == FlashPhase.failed || status == FlashPhase.uncertain,
            ),
            const SizedBox(height: 10),
          ],
          if (controller.cancelNote != null) ...[
            HintText(
              controller.cancelNote!,
              key: const ValueKey('flashCancelNote'),
              error: true,
            ),
            const SizedBox(height: 10),
          ],
          if (controller.errorText != null) ...[
            HintText(
              controller.errorText!,
              key: const ValueKey('flashError'),
              error: true,
            ),
            const SizedBox(height: 10),
          ],
          if (receipt == null)
            const HintText(
              'No receipt reached the page. The service may still have saved '
              'one at the job path shown below; refresh history to see it.',
            )
          else ...[
            LabeledValue(label: 'Status', value: '${receipt['status'] ?? ''}'),
            LabeledValue(label: 'Serial', value: '${receipt['serial'] ?? ''}'),
            LabeledValue(label: 'Device', value: '${receipt['device'] ?? ''}'),
            LabeledValue(
              label: 'Product',
              value: '${receipt['product'] ?? ''}',
              monospace: true,
            ),
            LabeledValue(
              label: 'Expected product',
              value: '${receipt['expectedProduct'] ?? ''}',
              monospace: true,
            ),
            LabeledValue(
              label: 'Mode start → end',
              value:
                  '${receipt['modeStart'] ?? ''} → '
                  '${receipt['modeEnd'] ?? ''}',
            ),
            LabeledValue(
              label: 'Version',
              value: '${receipt['version'] ?? ''}',
            ),
            LabeledValue(label: 'Job', value: '${receipt['job'] ?? ''}'),
            LabeledValue(
              label: 'Started',
              value: '${receipt['startedAt'] ?? ''}',
            ),
            LabeledValue(
              label: 'Finished',
              value: '${receipt['finishedAt'] ?? ''}',
            ),
            LabeledValue(
              label: 'Verification',
              value: '${verification?['status'] ?? 'unknown'}',
            ),
            if (verification?['detail'] != null)
              HintText('${verification!['detail']}'),
            if (failure != null) ...[
              const Divider(height: 20),
              LabeledValue(
                label: 'Failure',
                value: '${failure['name'] ?? ''}: ${failure['message'] ?? ''}',
              ),
              LabeledValue(label: 'Stage', value: '${failure['stage'] ?? ''}'),
              if (failure['uncertain'] == true)
                const HintText(
                  'The failure is marked uncertain: a write may have reached '
                  'the phone. Do not retry automatically.',
                  error: true,
                ),
            ],
            if (steps.isNotEmpty) ...[
              const Divider(height: 20),
              const FieldLabel('STEPS'),
              const SizedBox(height: 6),
              for (final step in steps)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 64,
                        child: Text(
                          '${step['status'] ?? ''}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: step['status'] == 'ok'
                                ? theme.colorScheme.primary
                                : theme.colorScheme.error,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '${step['title'] ?? ''}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            for (final warning in warnings)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: HintText('Warning: $warning', error: true),
              ),
            if (receipt['uncertain'] == true)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: HintText(
                  'The receipt is marked uncertain: a write may not have been '
                  'confirmed. Do not retry blindly.',
                  key: ValueKey('receiptUncertain'),
                  error: true,
                ),
              ),
            for (final error in cleanup)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: HintText('Cleanup: $error', error: true),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  key: const ValueKey('downloadFlashReceipt'),
                  onPressed: () => _download(context),
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Download receipt'),
                ),
                const SizedBox(width: 10),
                TextButton.icon(
                  key: const ValueKey('saveFlashLogBottom'),
                  onPressed: controller.log.isEmpty ? null : controller.saveLog,
                  icon: const Icon(Icons.save_alt, size: 16),
                  label: const Text('Save log'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          HintText(
            'The OTA is read in place and no local job exists, so the service '
            'returns the receipt to this page. Download it after flashing; it '
            'is not written into a local folder.',
          ),
        ],
      ),
    );
  }

  Future<void> _download(BuildContext context) async {
    final message = await controller.downloadReceipt();
    if (!context.mounted || message == null) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
