import 'dart:async';

import 'package:flutter/material.dart';

import '../api/flasher_api.dart';
import '../api/platform_bridge.dart';
import '../widgets/common.dart';
import 'flash_target.dart';

/// Opens the fastboot device sheet: grant one through WebUSB, or pick from
/// devices this page already has permission for.
///
/// Returns `{serial, label}` or null when the sheet closes without a device.
Future<Map<String, Object?>?> showFastbootDeviceSheet(
  BuildContext context, {
  required FlasherApi api,
  required PlatformBridge bridge,
}) {
  return showModalBottomSheet<Map<String, Object?>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _FastbootDeviceSheet(api: api, bridge: bridge),
  );
}

class _FastbootDeviceSheet extends StatefulWidget {
  const _FastbootDeviceSheet({required this.api, required this.bridge});

  final FlasherApi api;
  final PlatformBridge bridge;

  @override
  State<_FastbootDeviceSheet> createState() => _FastbootDeviceSheetState();
}

class _FastbootDeviceSheetState extends State<_FastbootDeviceSheet> {
  List<Map<String, Object?>> _devices = const [];
  bool _loading = true;
  bool _choosing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadGranted());
  }

  Future<void> _loadGranted() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await widget.api.fastbootDevices();
      if (!mounted) return;
      final values = response['devices'];
      final error = response['error'];
      setState(() {
        _devices = [
          if (values is List)
            for (final device in values)
              if (device is Map && device['serial'] is String)
                Map<String, Object?>.from(device),
        ];
        _loading = false;
        _error = error == null
            ? null
            : 'Could not list granted devices: ${describeLinkFailure(error)}';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not list granted devices: $error';
      });
    }
  }

  Future<void> _choose() async {
    if (_choosing) return;
    setState(() {
      _choosing = true;
      _error = null;
    });
    // The chooser call must run before any await in this click task.
    final FastbootUsbDevice? chosen;
    try {
      chosen = await widget.bridge.chooseFastbootDevice();
    } on FastbootUsbException catch (error) {
      if (!mounted) return;
      setState(() {
        _choosing = false;
        _error = '${_guidance(error.kind)}\n$error';
      });
      return;
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _choosing = false;
        _error = 'Could not open the USB chooser: $error';
      });
      return;
    }
    if (!mounted) return;
    if (chosen == null) {
      setState(() {
        _choosing = false;
        _error =
            'No device was chosen. Put the phone in bootloader fastboot, then '
            'choose it again.';
      });
      return;
    }
    Navigator.of(
      context,
    ).pop({'serial': chosen.serial, 'label': chosen.label, 'transport': 'usb'});
  }

  String _guidance(FastbootUsbFailure kind) => switch (kind) {
    FastbootUsbFailure.unsupported =>
      'This browser has no WebUSB. Open the app in a current Chromium browser.',
    FastbootUsbFailure.insecureContext =>
      'WebUSB needs a secure page. Open the app over HTTPS or on localhost.',
    FastbootUsbFailure.permission =>
      'USB permission was refused. Allow USB access for this site, then try '
          'again.',
    FastbootUsbFailure.noSerial =>
      'The chosen device did not expose a fastboot serial. Reconnect it with '
          'a USB cable and choose it again.',
    FastbootUsbFailure.other =>
      'The browser could not grant the device. Reconnect it and try again.',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canChoose = widget.bridge.canChooseFastbootDevice;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Fastboot device', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              const HintText(
                'Only USB devices with the fastboot interface (ff/42/03) are '
                'offered. The page passes the serial; the service reopens the '
                'phone itself.',
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const ValueKey('chooseFastbootDevice'),
                onPressed: canChoose && !_choosing ? _choose : null,
                icon: const Icon(Icons.usb, size: 18),
                label: Text(
                  _choosing ? 'Waiting for the chooser…' : 'Choose USB device',
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('refreshGrantedDevices'),
                onPressed: _loading ? null : _loadGranted,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Check already granted'),
              ),
              if (!canChoose) ...[
                const SizedBox(height: 8),
                const HintText(
                  'This page cannot open a WebUSB chooser. Use current Chrome, '
                  'Edge or Chromium over HTTPS or localhost, outside an '
                  'embedded webview.',
                  error: true,
                ),
              ],
              const SizedBox(height: 16),
              if (_loading)
                const LinearProgressIndicator(minHeight: 3)
              else if (_error != null)
                HintText(_error!, error: true)
              else if (_devices.isEmpty)
                const HintText(
                  'No granted fastboot device. Connect the phone in '
                  'bootloader fastboot mode, then choose it.',
                )
              else ...[
                const FieldLabel('GRANTED DEVICES'),
                const SizedBox(height: 6),
                for (final device in _devices)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.usb, size: 20),
                    title: Text(
                      '${device['serial']}',
                      key: ValueKey('granted-${device['serial']}'),
                    ),
                    subtitle: Text(_subtitle(device)),
                    onTap: () => Navigator.of(context).pop(device),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _subtitle(Map<String, Object?> device) {
    final parts = [
      if (device['label'] is String && '${device['label']}'.isNotEmpty)
        '${device['label']}',
      if (device['transport'] is String && '${device['transport']}'.isNotEmpty)
        '${device['transport']}',
    ];
    return parts.isEmpty ? 'Fastboot device' : parts.join(' · ');
  }
}
