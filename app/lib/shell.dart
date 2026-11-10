import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

import 'docs/docs_page.dart';
import 'environment/environment_page.dart';
import 'flash/flash_controller.dart';
import 'flash/flash_page.dart';
import 'flash/flash_target.dart';
import 'preferences.dart';
import 'runtime.dart';
import 'setup/setup_page.dart';
import 'setup/setup_state.dart';

/// The destinations of the desktop app, browser-only.
enum AppPage { setup, flash, environment, documentation }

/// The sidebar, page header and the pages themselves.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.runtime,
    required this.tables,
    required this.environment,
    required this.preferences,
  });

  final AppRuntime runtime;
  final UpstreamTables tables;
  final EnvironmentInfo environment;
  final SetupPreferences preferences;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final SetupState _setup = SetupState(
    runtime: widget.runtime,
    tables: widget.tables,
    environment: widget.environment,
    preferences: widget.preferences,
  );

  AppPage _page = AppPage.setup;
  FlashController? _flash;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreCheckpoint());
  }

  /// A reload restores the last checkpoint as an inspection-only receipt.
  ///
  /// The run it describes is gone with the page: nothing is resumed, no
  /// command is replayed and a new preparation and confirmation are required
  /// to write again.
  Future<void> _restoreCheckpoint() async {
    final checkpoint = await widget.runtime.bridge.readFlashCheckpoint();
    if (!mounted || checkpoint == null || checkpoint.isEmpty) return;
    if (_flash != null) return;
    final controller = FlashController(
      api: widget.runtime.service,
      bridge: widget.runtime.bridge,
      environment: widget.environment,
      upstreamBase: widget.runtime.upstreamBase,
      checkpoint: checkpoint,
    );
    setState(() {
      _flash = controller;
      _page = AppPage.flash;
    });
    unawaited(controller.start());
  }

  static const _titles = {
    AppPage.setup: (
      'Flash or export',
      'Read a full OTA in place, then flash it or save the package.',
    ),
    AppPage.flash: (
      'Flash device',
      'Answer the plan, confirm the exact phone, then write.',
    ),
    AppPage.environment: (
      'Environment',
      'Check your local engine and verify the storage and device support.',
    ),
    AppPage.documentation: (
      'Documentation',
      'Guides and reference for flashing your phone.',
    ),
  };

  static const _icons = {
    AppPage.setup: Icons.flash_on_outlined,
    AppPage.flash: Icons.flash_on,
    AppPage.environment: Icons.settings_outlined,
    AppPage.documentation: Icons.help_outline,
  };

  List<AppPage> get _destinations => [
    AppPage.setup,
    if (_flash != null) AppPage.flash,
    AppPage.environment,
    AppPage.documentation,
  ];

  void _navigate(AppPage page) {
    if (page == AppPage.flash && _flash == null) return;
    if (_flash?.busy == true && page != AppPage.flash) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The flash is still running. Stay here until it finishes or '
            'stop it; leaving does not stop the phone write.',
          ),
        ),
      );
      return;
    }
    setState(() => _page = page);
  }

  void _openFlash(FlashTarget target) {
    final current = _flash;
    if (current != null && current.busy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'A flash is already running. Stop it or wait for the receipt '
            'before starting another.',
          ),
        ),
      );
      return;
    }
    current?.dispose();
    final controller = FlashController(
      api: widget.runtime.service,
      bridge: widget.runtime.bridge,
      environment: widget.environment,
      target: target,
      upstreamBase: widget.runtime.upstreamBase,
    );
    setState(() {
      _flash = controller;
      _page = AppPage.flash;
    });
    unawaited(controller.start());
  }

  Future<void> _flashDirect() async {
    final ota = _setup.directFlashOta;
    final base = _setup.directFlashBase;
    final selection = _setup.selectionMap;
    if (ota == null || selection == null) return;
    if (_setup.needsBase && base == null) return;
    // Continue is an explicit new run: the previous receipt is not restored
    // into it.
    await widget.runtime.bridge.clearFlashCheckpoint();
    if (!mounted) return;
    _openFlash(
      FlashTarget(
        ota: ota,
        base: base,
        bloat: _setup.directFlashBloat,
        vulnerableAbl: _setup.vulnerableAbl,
        selection: Map<String, Object?>.from(selection),
        label: '${_setup.deviceDisplay} / ${_setup.kind}',
      ),
    );
  }

  @override
  void dispose() {
    _setup.dispose();
    _flash?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1024;
        final title = _titles[_page]!;
        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title.$1, style: theme.textTheme.headlineMedium),
                      const SizedBox(height: 4),
                      Text(
                        title.$2,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Expanded(child: _pageView()),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  _setup.workflowHint,
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 0.9,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Text(
                  'Flutter web  /  Local workspace',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        );

        if (!wide) {
          return Scaffold(
            appBar: AppBar(
              title: Row(
                children: [
                  Icon(
                    Icons.layers,
                    color: theme.colorScheme.primary,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  const Text('Flasher Builder'),
                ],
              ),
            ),
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: content,
              ),
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _destinations.indexOf(_page),
              onDestinationSelected: (index) => _navigate(_destinations[index]),
              destinations: [
                for (final page in _destinations)
                  NavigationDestination(
                    icon: Icon(_icons[page]),
                    label: _shortLabel(page),
                  ),
              ],
            ),
          );
        }

        return Scaffold(
          body: Row(
            children: [
              NavigationRail(
                extended: constraints.maxWidth >= 1220,
                minExtendedWidth: 216,
                leading: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 18, 12, 26),
                  child: _Brand(compact: constraints.maxWidth < 1220),
                ),
                selectedIndex: _destinations.indexOf(_page),
                onDestinationSelected: (index) =>
                    _navigate(_destinations[index]),
                labelType: constraints.maxWidth >= 1220
                    ? null
                    : NavigationRailLabelType.all,
                destinations: [
                  for (final page in _destinations)
                    NavigationRailDestination(
                      icon: Icon(_icons[page]),
                      label: Text(_shortLabel(page)),
                    ),
                ],
                trailing: const SizedBox.shrink(),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(30, 24, 30, 12),
                    child: content,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _pageView() {
    return switch (_page) {
      AppPage.setup => SetupPage(
        setup: _setup,
        onFlashDirect: _flashDirect,
      ),
      AppPage.flash => FlashPage(
        controller: _flash!,
        onBack: () => _navigate(AppPage.setup),
      ),
      AppPage.environment => EnvironmentPage(
        runtime: widget.runtime,
        tables: widget.tables,
        initial: widget.environment,
        setup: _setup,
      ),
      AppPage.documentation => DocsPage(runtime: widget.runtime),
    };
  }

  String _shortLabel(AppPage page) => switch (page) {
    AppPage.setup => 'Flash or export',
    AppPage.flash => 'Flash',
    AppPage.environment => 'Environment',
    AppPage.documentation => 'Documentation',
  };
}

class _Brand extends StatelessWidget {
  const _Brand({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (compact) {
      return Icon(Icons.layers, color: theme.colorScheme.primary, size: 30);
    }
    return Row(
      children: [
        Icon(Icons.layers, color: theme.colorScheme.primary, size: 30),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Flasher', style: theme.textTheme.titleMedium),
            Text(
              'BUILDER STUDIO',
              style: theme.textTheme.labelSmall?.copyWith(
                letterSpacing: 1.3,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
