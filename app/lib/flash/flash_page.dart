import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flasher_web_core/flasher_web_core.dart'
    show FlashConnection, FlashRecovery, WriteCertainty;

import '../widgets/common.dart';
import 'device_sheet.dart';
import 'flash_controller.dart';

/// The guided flash flow: one screen and one primary action at a time.
///
/// Setup is the shell's page; this flow starts at Connect and renders the
/// core's flow state on Check, Confirm, Flash, Recover and Done. Every screen
/// shows the same diagnostics, receipt and Stop affordances as secondary
/// actions and never starts a second write.
class FlashPage extends StatefulWidget {
  const FlashPage({super.key, required this.controller, required this.onBack});

  final FlashController controller;
  final VoidCallback onBack;

  @override
  State<FlashPage> createState() => _FlashPageState();
}

class _FlashPageState extends State<FlashPage> {
  final _logScroll = ScrollController();
  FlashScreen? _lastScreen;
  FlashConnection? _lastConnection;
  WriteCertainty? _lastCertainty;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _lastScreen = widget.controller.screen;
    _lastConnection = widget.controller.connection;
    _lastCertainty = widget.controller.certainty;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _logScroll.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (_logScroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_logScroll.hasClients) return;
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      });
    }
    final controller = widget.controller;
    final screen = controller.screen;
    final connection = controller.connection;
    final certainty = controller.certainty;
    final changed = screen != _lastScreen ||
        connection != _lastConnection ||
        certainty != _lastCertainty;
    _lastScreen = screen;
    _lastConnection = connection;
    _lastCertainty = certainty;
    if (!changed) return;
    final heading = flashScreenHeading(screen);
    final parts = [
      heading.title,
      controller.connectionLabel,
      if (certainty == WriteCertainty.uncertain) 'Write certainty: uncertain',
    ];
    SemanticsService.sendAnnouncement(
      View.of(context),
      parts.join('. '),
      TextDirection.ltr,
    );
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

  void _showNotInList() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('The phone is not in the list'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Fastboot is a bootloader feature, not an Android state:'),
              SizedBox(height: 10),
              Text(
                '1. Turn the phone off, then hold Power + Volume-Down until '
                'the bootloader screen appears. A phone showing a charging '
                'battery or the Android system is not in fastboot.',
              ),
              Text(
                '2. Use a data cable in a USB-A or a known-good USB-C port. '
                'Charge-only cables never enumerate, and some hubs and '
                'docks hide the fastboot interface.',
              ),
              Text(
                '3. Allow USB debugging and OEM unlocking on the phone if the '
                'bootloader screen asks for it; a locked screen may refuse the '
                'chooser.',
              ),
              Text(
                '4. On Linux, check that no udev rule or running tool holds '
                'the interface; on Windows, install the device driver and '
                'close other flashing programs.',
              ),
              SizedBox(height: 10),
              Text(
                'The page passes only the serial to the flasher; the phone '
                'itself must answer fastboot getvar.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showDiagnostics({String? raw}) async {
    final controller = widget.controller;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Diagnostics'),
        content: SizedBox(
          width: 640,
          height: 460,
          child: SingleChildScrollView(
            child: SelectableText(
              raw ?? controller.diagnosticsText,
              key: const ValueKey('diagnosticsText'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => widget.controller.saveLog(),
            child: const Text('Save log'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final screen = controller.screen;
        final heading = flashScreenHeading(screen);
        final theme = Theme.of(context);
        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StepRail(screen: screen),
            const SizedBox(height: 14),
            Text(
              heading.title,
              key: const ValueKey('flowTitle'),
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            Text(
              heading.detail,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            if (controller.updateReady) ...[
              const SizedBox(height: 12),
              _UpdateBanner(controller: controller),
            ],
            if (controller.writesSupported == false) ...[
              const SizedBox(height: 12),
              const HintText(
                'This browser context reports no WebUSB support (usb.web). '
                'Open the app in a current Chromium browser over HTTPS or '
                'localhost; flashing stays disabled.',
                error: true,
              ),
            ],
            const SizedBox(height: 16),
            ..._screen(controller, screen),
            const SizedBox(height: 18),
            _Footer(
              controller: controller,
              onBack: widget.onBack,
              onDiagnostics: _showDiagnostics,
            ),
          ],
        );
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: content,
            ),
          ),
        );
      },
    );
  }

  List<Widget> _screen(FlashController controller, FlashScreen screen) {
    return switch (screen) {
      FlashScreen.connect => _connect(controller),
      FlashScreen.check => _check(controller),
      FlashScreen.confirm => _confirm(controller),
      FlashScreen.flash => _flash(controller),
      FlashScreen.recover => _recover(controller),
      FlashScreen.done => _done(controller),
    };
  }

  // ------------------------------------------------------------- Connect

  List<Widget> _connect(FlashController controller) {
    final theme = Theme.of(context);
    final serial = controller.serial;
    final hasGrant = controller.hasGrant;
    final primary = hasGrant ? 'Check phone' : 'Choose phone';
    return [
      SectionCard(
        key: const ValueKey('screenConnect'),
        title: 'Connection',
        trailing: _ConnectionBadge(controller: controller),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                controller.connectionLabel,
                key: const ValueKey('connectionStatus'),
                style: theme.textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 6),
            if (controller.devicesLoading)
              const LinearProgressIndicator(minHeight: 3)
            else if (controller.devicesError != null)
              HintText(
                controller.devicesError!,
                key: const ValueKey('connectError'),
                error: true,
              )
            else if (controller.notice != null)
              HintText(
                controller.notice!,
                key: const ValueKey('connectNotice'),
              )
            else
              const HintText(
                'Only USB devices with the fastboot interface (ff/42/03) are '
                'offered, in bootloader fastboot. A phone that is still '
                'starting Android cannot answer fastboot commands.',
              ),
            if (serial != null) ...[
              const SizedBox(height: 12),
              Text(
                serial,
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
            ],
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const ValueKey('connectPrimary'),
                onPressed: controller.writesSupported
                    ? (hasGrant
                          ? controller.checkPhone
                          : controller.chooseDevice)
                    : null,
                icon: const Icon(Icons.usb, size: 18),
                label: Text(primary),
              ),
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
      ),
      const SizedBox(height: 14),
      SectionCard(
        title: 'One phone, one serial',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const HintText(
              'The page passes only the serial to the flasher. The service '
              'reopens that exact granted phone, so a second phone cannot be '
              'written by mistake. Regrant the same phone when the app asks '
              'after a reboot.',
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 6,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('chooseAnotherPhone'),
                  onPressed: controller.writesSupported
                      ? _openDeviceSheet
                      : null,
                  icon: const Icon(Icons.list_alt, size: 18),
                  label: const Text('Other granted phones'),
                ),
                TextButton.icon(
                  key: const ValueKey('notInTheList'),
                  onPressed: _showNotInList,
                  icon: const Icon(Icons.help_outline, size: 18),
                  label: const Text('Not in the list?'),
                ),
              ],
            ),
          ],
        ),
      ),
    ];
  }

  // --------------------------------------------------------------- Check

  List<Widget> _check(FlashController controller) {
    final prepared = controller.prepared;
    return [
      SectionCard(
        key: const ValueKey('screenCheck'),
        title: 'Read-only checks',
        trailing: controller.preparing
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : _PhaseBadge(prepared?.resolved == true ? 'RESOLVED' : 'READ-ONLY'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (controller.devicesLoading || controller.preparing)
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: LinearProgressIndicator(minHeight: 3),
              ),
            LabeledValue(
              label: 'Serial',
              value: controller.serial ?? 'not chosen',
              monospace: true,
            ),
            LabeledValue(
              label: 'Actual mode',
              value: prepared?.mode ?? 'not checked',
              monospace: true,
            ),
            LabeledValue(
              label: 'Package',
              value: controller.targetLabel,
            ),
            LabeledValue(label: 'Job', value: controller.jobId),
            if (controller.prepareError != null) ...[
              const SizedBox(height: 10),
              HintText(
                controller.prepareError!,
                key: const ValueKey('prepareError'),
                error: true,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('prepareEvidence'),
                  onPressed: () => _showDiagnostics(),
                  icon: const Icon(Icons.code, size: 16),
                  label: const Text('Show raw evidence'),
                ),
              ),
            ],
            if (prepared != null && !prepared.modeOk) ...[
              const SizedBox(height: 8),
              const HintText(
                'The phone is not in bootloader fastboot. Reboot it there, '
                'check the phone again and prepare a new plan.',
                key: ValueKey('modeMismatch'),
                error: true,
              ),
            ],
            for (final warning in prepared?.warnings ?? const <String>[])
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: HintText('Warning: $warning', error: true),
              ),
            if (controller.notice != null) ...[
              const SizedBox(height: 8),
              HintText(controller.notice!),
            ],
          ],
        ),
      ),
      const SizedBox(height: 14),
      _AnswersCard(controller: controller),
      if (controller.planSteps.isNotEmpty) ...[
        const SizedBox(height: 14),
        _PlanCard(controller: controller),
      ],
      const SizedBox(height: 14),
      Row(
        children: [
          FilledButton.icon(
            key: const ValueKey('reviewPlan'),
            onPressed: controller.ready && !controller.preparing
                ? controller.reviewPlan
                : null,
            icon: const Icon(Icons.fact_check_outlined, size: 18),
            label: const Text('Review plan'),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            key: const ValueKey('prepareAgain'),
            onPressed: controller.preparing ? null : controller.prepare,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Prepare again'),
          ),
        ],
      ),
      if (!controller.ready && !controller.preparing) ...[
        const SizedBox(height: 6),
        HintText(
          controller.blockingReason ?? 'The plan is not resolved yet.',
          key: const ValueKey('reviewBlocked'),
          error: true,
        ),
      ],
    ];
  }

  // ------------------------------------------------------------- Confirm

  List<Widget> _confirm(FlashController controller) {
    final prepared = controller.prepared;
    final theme = Theme.of(context);
    final serial = controller.serial ?? prepared?.serial ?? '';
    return [
      SectionCard(
        key: const ValueKey('screenConfirm'),
        title: 'This writes to the phone',
        trailing: _PhaseBadge('NOT STARTED'),
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
                    'Serial: $serial',
                    key: const ValueKey('confirmSerialValue'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                  Text(
                    'Mode: ${prepared?.mode ?? 'unknown'}',
                    style: theme.textTheme.bodySmall,
                  ),
                  Text(
                    'OTA: ${controller.targetLabel}'
                    '${prepared == null ? '' : ' · ${prepared.version}'}',
                    style: theme.textTheme.bodySmall,
                  ),
                  Text(
                    'Job: ${controller.jobId}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            const HintText(
              'A write is accepted when the phone answers OKAY. That is not a '
              'readback verification of the bytes. Wiping and root installation '
              'stay manual on the phone.',
            ),
            if (prepared != null && prepared.confirmation.isNotEmpty)
              ExpansionTile(
                key: const ValueKey('confirmationText'),
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
            for (final warning in prepared?.warnings ?? const <String>[])
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: HintText('Warning: $warning', error: true),
              ),
            if (controller.superPreflight != null) ...[
              const SizedBox(height: 8),
              HintText(
                controller.needsWipeSuper
                    ? 'Super preflight: clear super is required and is '
                          'offered only in recovery, with its own confirmation.'
                    : 'Super preflight: ${controller.superPreflight}',
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 14),
      _PlanCard(controller: controller),
      const SizedBox(height: 14),
      _ConfirmationCard(controller: controller),
    ];
  }

  // --------------------------------------------------------------- Flash

  List<Widget> _flash(FlashController controller) {
    final theme = Theme.of(context);
    final total = controller.totalSteps;
    final progress = controller.progress.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return [
      SectionCard(
        key: const ValueKey('screenFlash'),
        title: 'Progress',
        trailing: _PhaseBadge(controller.writing ? 'WRITING' : 'STARTING'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              total > 0
                  ? 'Step ${controller.stepIndex} of $total'
                  : 'Starting the first step…',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              controller.stepTitle.isEmpty
                  ? 'Waiting for the service'
                  : controller.stepTitle,
              key: const ValueKey('currentStep'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: total <= 0
                  ? null
                  : (controller.stepIndex / total).clamp(0.0, 1.0),
              minHeight: 5,
            ),
            if (progress.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final entry in progress)
                ByteProgress(
                  label: entry.key,
                  done: entry.value.done,
                  total: entry.value.total,
                ),
            ],
            const SizedBox(height: 10),
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
                          'Grant serial ${controller.waitingSerial} again in '
                              'the USB chooser. Another phone is refused.',
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        key: const ValueKey('regrantDevice'),
                        onPressed: controller.regranting
                            ? null
                            : controller.regrantDevice,
                        icon: const Icon(Icons.usb, size: 18),
                        label: const Text('Grant the same phone again'),
                      ),
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
            const SizedBox(height: 10),
            FieldLabel('LAST REPLY'),
            const SizedBox(height: 4),
            Text(
              controller.lastReply.isEmpty
                  ? 'No reply yet.'
                  : controller.lastReply,
              key: const ValueKey('lastReply'),
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
            if (controller.wakeLockMissing) ...[
              const SizedBox(height: 8),
              const HintText(
                'This browser cannot keep the screen awake. Keep this tab '
                'visible and do not let the phone or computer sleep.',
                key: ValueKey('wakeLockMissing'),
                error: true,
              ),
            ],
            const SizedBox(height: 8),
            HintText(
              controller.waiting != null
                  ? 'A reboot is in progress. The app waits for the same '
                        'serial in the required mode; no write is repeated.'
                  : 'Do not unplug the phone. A mode change is reported here '
                        'before the run continues.',
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      Row(
        children: [
          FilledButton.icon(
            key: const ValueKey('stopFlash'),
            onPressed: controller.canStop && !controller.stopping
                ? controller.stop
                : null,
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: const Text('Stop further commands'),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            key: const ValueKey('flashDiagnostics'),
            onPressed: () => _showDiagnostics(),
            icon: const Icon(Icons.terminal, size: 16),
            label: const Text('Diagnostics'),
          ),
        ],
      ),
      const SizedBox(height: 6),
      const HintText(
        'Stop is not a rollback: no new command is sent after the in-flight '
        'one, and an uncertain write stays uncertain.',
        error: true,
      ),
      if (controller.notice != null) ...[
        const SizedBox(height: 8),
        HintText(controller.notice!),
      ],
    ];
  }

  // ------------------------------------------------------------- Recover

  List<Widget> _recover(FlashController controller) {
    final theme = Theme.of(context);
    final primary = controller.primaryRecovery;
    final primaryName = primary?['action'];
    final others = [
      for (final action in controller.recoveryActions)
        if (action['action'] != primaryName &&
            action['action'] != FlashRecovery.stopRun.name)
          action,
    ];
    final powerCycleOffered = controller.recoveryActions.any(
      (action) => action['action'] == FlashRecovery.recoverPowerCycle.name,
    );
    return [
      if (controller.uncertain)
        Container(
          key: const ValueKey('uncertainBanner'),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'UNCERTAIN WRITE',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'A write may have reached the phone without confirmation. '
                'Reconnecting, a successful read, Stop or a reboot cannot '
                'erase that. Choose an explicit action; nothing is resent '
                'automatically.',
              ),
            ],
          ),
        ),
      if (controller.uncertain) const SizedBox(height: 14),
      SectionCard(
        key: const ValueKey('screenRecover'),
        title: 'What happened',
        trailing: Text(
          controller.uncertain ? 'UNCONFIRMED' : 'FAILED',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.error,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              controller.failedStepLabel,
              key: const ValueKey('failureStepTitle'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            if (controller.plainFailure != null)
              HintText(
                controller.plainFailure!,
                key: const ValueKey('failureMessage'),
                error: true,
              ),
            if (controller.needsWipeSuper) ...[
              const SizedBox(height: 8),
              HintText(
                FlashController.superPreflightQuestion,
                key: const ValueKey('superPreflight'),
                error: true,
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('showRawEvidence'),
                onPressed: () =>
                    _showDiagnostics(raw: controller.rawFailure),
                icon: const Icon(Icons.code, size: 16),
                label: const Text('Show raw evidence'),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      SectionCard(
        title: 'Recovery actions',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (primary == null) ...[
              if (controller.busy)
                const LinearProgressIndicator(minHeight: 3)
              else
                const HintText(
                  'The service offered no action for this run besides Stop. '
                  'Save the receipt and check the phone before starting a new '
                  'plan.',
                ),
            ] else
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: const ValueKey('recoverPrimary'),
                  onPressed: controller.canRecover && !controller.busy
                      ? () => _runAction(controller, primary)
                      : null,
                  icon: const Icon(Icons.build_circle_outlined, size: 18),
                  label: Text(controller.recoveryTitle(primary)),
                ),
              ),
            if (primary != null) ...[
              const SizedBox(height: 6),
              HintText(
                controller.canRecover
                    ? _actionExplanation(primary)
                    : 'Waiting for the service to finish this run before '
                          'another action is offered. Stop stays available '
                          'when the receipt allows it.',
              ),
            ],
            if (others.isNotEmpty) ...[
              const SizedBox(height: 10),
              FieldLabel('OTHER EXPLICIT CHOICES'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  for (final action in others)
                    OutlinedButton(
                      key: ValueKey('recover-${action['action']}'),
                      onPressed: controller.canRecover && !controller.busy
                          ? () => _runAction(controller, action)
                          : null,
                      child: Text(controller.recoveryTitle(action)),
                    ),
                ],
              ),
            ],
            if (powerCycleOffered) ...[
              const SizedBox(height: 10),
              const HintText(
                FlashController.powerCycleInstructions,
                key: ValueKey('powerCycleInstructions'),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton.icon(
                  key: const ValueKey('stopFlashRun'),
                  onPressed: controller.canStop && !controller.busy
                      ? controller.stop
                      : null,
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  label: const Text('Stop further commands'),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  key: const ValueKey('recoverDiagnostics'),
                  onPressed: () => _showDiagnostics(),
                  icon: const Icon(Icons.terminal, size: 16),
                  label: const Text('Diagnostics'),
                ),
              ],
            ),
            if (controller.busy) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(minHeight: 3),
            ],
            if (controller.errorText != null) ...[
              const SizedBox(height: 8),
              HintText(
                controller.errorText!,
                key: const ValueKey('recoverError'),
                error: true,
              ),
            ],
          ],
        ),
      ),
    ];
  }

  String _actionExplanation(Map<String, Object?> action) {
    final name = '${action['action']}';
    return switch (name) {
      'retryRead' => 'Reopens the exact serial, checks the phone again and '
          'repeats only the failed read and the rest of the plan. Any earlier '
          'uncertain write stays uncertain.',
      'reconnectDevice' => 'Waits for the same serial, checks the phone '
          'again and resumes the refused or read-only step. Reconnecting never '
          'settles a write.',
      'recoverBootloader' => 'Checks the phone, reboots to bootloader, waits '
          'for the same serial and checks again. A paused uncertain run stays '
          'paused.',
      'recoverFastbootd' => 'Checks the phone, reboots to fastbootd, waits '
          'for the same serial and checks again. A paused uncertain run stays '
          'paused.',
      'recoverPowerCycle' => 'No reset command is sent. Confirm only after '
          'the phone was unplugged, powered off and reconnected in bootloader.',
      'rewriteStep' => 'Rewrites this step from byte zero after naming the '
          'serial. Only a completed replacement settles it; the earlier '
          'attempt stays in the receipt history.',
      'wipeSuper' => 'Checks the phone, verifies snapshot status is exactly '
          'none and flashes a metadata-only super image, then restarts the '
          'logical writes. The phone cannot boot until the run completes.',
      _ => 'The service decides what this action sends.',
    };
  }

  Future<void> _runAction(
    FlashController controller,
    Map<String, Object?> action,
  ) async {
    final recovery = FlashRecovery.values.firstWhere(
      (value) => value.name == '${action['action']}',
      orElse: () => FlashRecovery.stopRun,
    );
    if (recovery == FlashRecovery.stopRun) return;
    final serial = controller.serial;
    final destructive = action['confirmationRequired'] == true;
    final physical = action['powerCycleRequired'] == true;
    if (physical) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(controller.recoveryTitle(action)),
          content: const SingleChildScrollView(
            child: Text(FlashController.powerCycleInstructions),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const ValueKey('confirmPowerCycle'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('I have power-cycled the phone'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    } else if (destructive) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => _SerialConfirmationDialog(
          controller: controller,
          action: action,
          recovery: recovery,
        ),
      );
      if (accepted != true) return;
    }
    await controller.recover(
      recovery,
      confirmedSerial: destructive ? serial : null,
      powerCycled: physical,
    );
  }

  // ---------------------------------------------------------------- Done

  List<Widget> _done(FlashController controller) {
    final theme = Theme.of(context);
    final receipt = controller.receipt;
    final status = '${receipt?['status'] ?? ''}';
    final succeeded = status == 'succeeded' && !controller.uncertain;
    final steps = receipt?['steps'] is List
        ? [
            for (final step in receipt!['steps']! as List)
              if (step is Map) Map<String, Object?>.from(step),
          ]
        : const <Map<String, Object?>>[];
    final hashes = receipt?['image_sha256'] is Map
        ? {
            for (final entry in (receipt!['image_sha256']! as Map).entries)
              '${entry.key}': '${entry.value}',
          }
        : const <String, String>{};
    final abl = receipt?['abl_source'] is Map
        ? Map<String, Object?>.from(receipt!['abl_source']! as Map)
        : null;
    return [
      SectionCard(
        key: const ValueKey('screenDone'),
        title: succeeded
            ? 'The phone accepted every write'
            : controller.uncertain
            ? 'Finished with an uncertainty'
            : 'Stopped',
        trailing: Icon(
          succeeded ? Icons.check_circle : Icons.error_outline,
          color: succeeded
              ? theme.colorScheme.primary
              : theme.colorScheme.error,
          size: 20,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (controller.guidance != null) ...[
              HintText(
                controller.guidance!,
                key: const ValueKey('flashGuidance'),
                error: !succeeded,
              ),
              const SizedBox(height: 8),
            ],
            if (controller.restoredNote != null) ...[
              HintText(
                controller.restoredNote!,
                key: const ValueKey('restoredNote'),
                error: controller.uncertain,
              ),
              const SizedBox(height: 8),
            ],
            if (controller.workerLost) ...[
              const HintText(
                'The service worker stopped. The app does not restart it and '
                'never replays a write; check the phone, then prepare and '
                'confirm a new run.',
                key: ValueKey('workerLost'),
                error: true,
              ),
              const SizedBox(height: 8),
            ],
            if (controller.uncertain)
              const HintText(
                'An unconfirmed write stays uncertain: reconnecting, a '
                'successful read or a reboot cannot erase it. Do not retry '
                'blindly.',
                key: ValueKey('receiptUncertain'),
                error: true,
              ),
            if (controller.errorText != null) ...[
              const SizedBox(height: 8),
              HintText(
                controller.errorText!,
                key: const ValueKey('flashError'),
                error: true,
              ),
            ],
            if (receipt == null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: HintText(
                  'No receipt reached the page. Without one, inspect the '
                  'phone before preparing another run.',
                ),
              )
            else ...[
              const Divider(height: 20),
              LabeledValue(label: 'Status', value: status),
              LabeledValue(
                label: 'Device',
                value: '${receipt['device'] ?? ''}',
              ),
              LabeledValue(
                label: 'Serial',
                value: '${receipt['serial'] ?? ''}',
                monospace: true,
              ),
              LabeledValue(
                label: 'Version',
                value: '${receipt['otaVersion'] ?? receipt['version'] ?? ''}',
              ),
              LabeledValue(
                label: 'Verification',
                value: '${(receipt['verification'] is Map) ? (receipt['verification'] as Map)['status'] ?? 'not-run' : 'not-run'} '
                    '(OKAY is not a readback)',
              ),
              LabeledValue(
                label: 'ARB',
                value: _arbText(receipt['arb']),
                monospace: true,
              ),
              if (abl != null)
                LabeledValue(
                  label: 'ABL source',
                  value: '${abl['version'] ?? ''} · ${abl['sha256'] ?? ''} · '
                      '${abl['bytes'] ?? ''} bytes',
                  monospace: true,
                ),
              if (hashes.isNotEmpty) ...[
                const Divider(height: 20),
                const FieldLabel('IMAGE SHA-256'),
                const SizedBox(height: 6),
                for (final entry in hashes.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 150,
                          child: Text(
                            entry.key,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        Expanded(
                          child: SelectableText(
                            entry.value,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ],
                    ),
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
                          width: 72,
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
              for (final error in _stringList(receipt['cleanupErrors']))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: HintText('Cleanup: $error', error: true),
                ),
            ],
            const SizedBox(height: 10),
            const HintText(
              'The OTA is read in place, so no local job folder or history '
              'exists: the receipt is the only record.',
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      Row(
        children: [
          FilledButton.icon(
            key: const ValueKey('saveReceipt'),
            onPressed: receipt == null ? null : () => _download(),
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Save receipt'),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            key: const ValueKey('saveDiagnostics'),
            onPressed: controller.log.isEmpty ? null : () => _saveLog(),
            icon: const Icon(Icons.save_alt, size: 16),
            label: const Text('Save diagnostics'),
          ),
        ],
      ),
      if (receipt == null) ...[
        const SizedBox(height: 6),
        const HintText(
          'There is no receipt to save. Open Diagnostics for what this page '
          'knows before starting a new plan.',
          error: true,
        ),
      ],
    ];
  }

  Future<void> _download() async {
    final message = await widget.controller.downloadReceipt();
    if (!mounted || message == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveLog() async {
    final message = await widget.controller.saveLog();
    if (!mounted || message == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// The seven guided screens, with the current one highlighted.
class _StepRail extends StatelessWidget {
  const _StepRail({required this.screen});

  final FlashScreen screen;

  static const _labels = [
    'Setup',
    'Connect',
    'Check',
    'Confirm',
    'Flash',
    'Recover',
    'Done',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = screen.index + 1;
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var index = 0; index < _labels.length; index++)
          Container(
            key: ValueKey('rail-${_labels[index].toLowerCase()}'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: index == current
                  ? theme.colorScheme.primaryContainer
                  : index < current
                  ? theme.colorScheme.surfaceContainerHighest
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: index == current
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
              ),
            ),
            child: Text(
              '${index + 1} ${_labels[index]}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: index == current
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: index == current
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
            ),
          ),
      ],
    );
  }
}

class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.controller});

  final FlashController controller;

  @override
  Widget build(BuildContext context) {
    final ready =
        controller.connection == FlashConnection.ready ||
        controller.connection == FlashConnection.active;
    return _PhaseBadge(ready ? 'READY' : 'NOT READY');
  }
}

class _PhaseBadge extends StatelessWidget {
  const _PhaseBadge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error =
        label == 'UNCERTAIN' || label == 'FAILED' || label == 'UNCONFIRMED';
    final color = error ? theme.colorScheme.error : theme.colorScheme.primary;
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

class _AnswersCard extends StatelessWidget {
  const _AnswersCard({required this.controller});

  final FlashController controller;

  @override
  Widget build(BuildContext context) {
    final prepared = controller.prepared;
    if (prepared == null) {
      return const SectionCard(
        title: 'Answers',
        child: HintText('The plan appears once the phone answers.'),
      );
    }
    return SectionCard(
      title: 'Answers',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
                            onSelected: controller.busy
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
    if (steps.isEmpty) {
      return const SectionCard(
        title: 'Ordered plan',
        child: HintText('The plan outline appears after the first check.'),
      );
    }
    return SectionCard(
      key: const ValueKey('flashPlan'),
      title: 'Ordered writes',
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
        ],
      ),
    );
  }
}

class _ConfirmationCard extends StatelessWidget {
  const _ConfirmationCard({required this.controller});

  final FlashController controller;

  @override
  Widget build(BuildContext context) {
    final serial = controller.serial ?? controller.prepared?.serial ?? '';
    return SectionCard(
      key: const ValueKey('flashConfirmation'),
      title: 'Confirm the exact device',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CheckboxListTile(
            key: const ValueKey('confirmFlashDevice'),
            contentPadding: EdgeInsets.zero,
            value: controller.acknowledged,
            onChanged:
                controller.writesSupported &&
                    controller.ready &&
                    !controller.busy
                ? (value) => controller.setAcknowledged(value == true)
                : null,
            title: Text('I confirm serial $serial.'),
            subtitle: const Text(
              'Changing the phone, job or any answer clears this confirmation '
              'and the token.',
            ),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const ValueKey('startFlash'),
              onPressed: controller.canFlash ? controller.flash : null,
              icon: const Icon(Icons.flash_on, size: 18),
              label: Text('Flash $serial'),
            ),
          ),
          const SizedBox(height: 6),
          HintText(
            controller.blockingReason ?? 'The plan is resolved and confirmed.',
            key: const ValueKey('flashBlocked'),
            error: !controller.canFlash,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('editAnswers'),
              onPressed: controller.busy ? null : controller.editAnswers,
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Change answers'),
            ),
          ),
        ],
      ),
    );
  }
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({required this.controller});

  final FlashController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('updateBanner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              controller.canReloadNow
                  ? 'A new version of the app is ready. Reloading keeps the '
                        'latest receipt; it never resumes a write.'
                  : 'A new version of the app is ready. Finish or stop the '
                        'current run before reloading.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.tonal(
            key: const ValueKey('reloadForUpdate'),
            onPressed: controller.canReloadNow
                ? controller.reloadForUpdate
                : null,
            child: const Text('Reload'),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.controller,
    required this.onBack,
    required this.onDiagnostics,
  });

  final FlashController controller;
  final VoidCallback onBack;
  final Future<void> Function({String? raw}) onDiagnostics;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('backFromFlash'),
          onPressed: controller.busy ? null : onBack,
          icon: const Icon(Icons.arrow_back, size: 18),
          label: const Text('Back to setup'),
        ),
        TextButton.icon(
          key: const ValueKey('footerDiagnostics'),
          onPressed: () => onDiagnostics(),
          icon: const Icon(Icons.terminal, size: 16),
          label: const Text('Diagnostics'),
        ),
      ],
    );
  }
}

/// The separate serial-naming confirmation for a destructive recovery.
///
/// The action returns true only when the typed serial is exact and the
/// irreversibility notice is acknowledged. Nothing is sent before that.
class _SerialConfirmationDialog extends StatefulWidget {
  const _SerialConfirmationDialog({
    required this.controller,
    required this.action,
    required this.recovery,
  });

  final FlashController controller;
  final Map<String, Object?> action;
  final FlashRecovery recovery;

  @override
  State<_SerialConfirmationDialog> createState() =>
      _SerialConfirmationDialogState();
}

class _SerialConfirmationDialogState extends State<_SerialConfirmationDialog> {
  final _input = TextEditingController();
  bool _accepted = false;

  String get _serial => widget.controller.serial ?? '';

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wipe = widget.recovery == FlashRecovery.wipeSuper;
    final matches = _input.text == _serial && _serial.isNotEmpty;
    // Clear super names the serial again; a rewrite only needs an explicit
    // acknowledgement of what it replaces.
    final ready = wipe ? matches && _accepted : _accepted;
    return AlertDialog(
      title: Text(widget.controller.recoveryTitle(widget.action)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              wipe
                  ? widget.controller.superWarning
                  : 'This rewrites ${widget.controller.failedStepLabel} on '
                        'serial $_serial from byte zero. Earlier writes stay '
                        'applied and the earlier attempt stays in the receipt '
                        'history.',
            ),
            if (wipe) ...[
              const SizedBox(height: 10),
              const Text('Type the exact serial to confirm:'),
              TextField(
                key: const ValueKey('confirmSerialField'),
                controller: _input,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Device serial',
                  hintText: _serial,
                ),
                onChanged: (value) => setState(() {}),
              ),
              const SizedBox(height: 10),
              const Text(
                'The phone cannot boot until this run completes. Snapshot '
                'status must be exactly none.',
              ),
            ],
            const SizedBox(height: 10),
            CheckboxListTile(
              key: const ValueKey('confirmDestructive'),
              contentPadding: EdgeInsets.zero,
              value: _accepted,
              onChanged: wipe && !matches
                  ? null
                  : (value) => setState(() => _accepted = value == true),
              title: Text(
                wipe
                    ? 'I understand this cannot be undone and no rollback '
                          'follows.'
                    : 'I understand step '
                          '${widget.controller.failedStepLabel} on $_serial '
                          'is rewritten from byte zero.',
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('confirmDestructiveAction'),
          onPressed: ready ? () => Navigator.of(context).pop(true) : null,
          child: Text(
            wipe
                ? 'Clear super on $_serial'
                : 'Rewrite from byte zero',
          ),
        ),
      ],
    );
  }
}

/// The ARB index the receipt carries, or `not reported`.
String _arbText(Object? arb) {
  if (arb is Map) {
    final major = arb['major'];
    final minor = arb['minor'];
    final index = arb['index'];
    if (major != null || minor != null || index != null) {
      return 'major $major · minor $minor · index $index';
    }
    return arb.entries.map((entry) => '${entry.key}: ${entry.value}').join(
      ' · ',
    );
  }
  return arb == null ? 'not reported' : '$arb';
}

List<String> _stringList(Object? value) => value is List
    ? [
        for (final item in value)
          if (item is String) item,
      ]
    : const <String>[];
