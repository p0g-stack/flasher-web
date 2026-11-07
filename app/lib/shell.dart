import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

import 'build/build_controller.dart';
import 'build/hosted_api.dart';
import 'build/output_page.dart';
import 'docs/docs_page.dart';
import 'environment/environment_page.dart';
import 'flash/flash_controller.dart';
import 'flash/flash_page.dart';
import 'flash/flash_target.dart';
import 'history/history_page.dart';
import 'preferences.dart';
import 'runtime.dart';
import 'setup/setup_page.dart';
import 'setup/setup_state.dart';

/// The destinations of the desktop app, browser-only.
enum AppPage { setup, output, flash, history, environment, documentation }

/// The sidebar, page header and the pages themselves.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.runtime,
    required this.tables,
    required this.environment,
    required this.preferences,
    this.hosted,
  });

  final AppRuntime runtime;
  final UpstreamTables tables;
  final EnvironmentInfo environment;
  final SetupPreferences preferences;

  /// Test seam for the hosted job client; production uses its same-origin
  /// default. Hosted requests never fall back to the local build worker.
  final HostedApiClient? hosted;

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
  late final BuildController _build = BuildController(
    api: widget.runtime.service,
    bridge: widget.runtime.bridge,
    hosted: widget.hosted,
  );

  AppPage _page = AppPage.setup;
  bool _hasOutput = false;
  FlashController? _flash;
  FlashTarget? _flashTarget;
  AppPage _flashBack = AppPage.setup;

  static const _titles = {
    AppPage.setup: (
      'New package',
      'Turn a full OTA into a ready-to-use flasher package.',
    ),
    AppPage.output: (
      'Build output',
      'Progress, results and logs for your latest task.',
    ),
    AppPage.flash: (
      'Flash device',
      'Answer the plan, confirm the exact phone, then write.',
    ),
    AppPage.history: (
      'Build history',
      'Your packages, checksums and build records in one place.',
    ),
    AppPage.environment: (
      'Environment',
      'Check your local engine and verify the build pipeline.',
    ),
    AppPage.documentation: (
      'Documentation',
      'Guides and reference for building your flasher package.',
    ),
  };

  static const _icons = {
    AppPage.setup: Icons.build_outlined,
    AppPage.output: Icons.terminal,
    AppPage.flash: Icons.flash_on,
    AppPage.history: Icons.history,
    AppPage.environment: Icons.settings_outlined,
    AppPage.documentation: Icons.help_outline,
  };

  List<AppPage> get _destinations => [
    AppPage.setup,
    if (_hasOutput) AppPage.output,
    if (_flashTarget != null) AppPage.flash,
    AppPage.history,
    AppPage.environment,
    AppPage.documentation,
  ];

  void _navigate(AppPage page) {
    if (page == AppPage.output && !_hasOutput) return;
    if (page == AppPage.flash && _flashTarget == null) return;
    if (_flash?.running == true && page != AppPage.flash) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The flash is still running. Stay here until it finishes or '
            'cancel it; leaving does not stop the phone write.',
          ),
        ),
      );
      return;
    }
    setState(() => _page = page);
  }

  void _openFlash(FlashTarget target, {required AppPage back}) {
    final current = _flash;
    if (current != null && current.running) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'A flash is already running. Cancel it or wait for the receipt '
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
      _flashTarget = target;
      _flashBack = back;
      _page = AppPage.flash;
    });
    unawaited(controller.start());
  }

  void _flashBuiltPackage() {
    final result = _build.result;
    final request = _build.request;
    final selection = request?['selection'];
    final job = result?['job'];
    if (result == null ||
        job is! String ||
        job.isEmpty ||
        selection is! Map) {
      return;
    }
    final summary = _build.summary;
    final device = '${selection['device'] ?? ''}';
    final kind = '${selection['kind'] ?? ''}';
    final label = summary == null
        ? '$device / $kind'
        : '${summary['device'] ?? device} / ${summary['kind'] ?? kind}';
    final selectionMap = Map<String, Object?>.from(selection);
    if (result['hosted'] == true) {
      final sha256 = result['sha256'];
      final bytes = result['bytes'];
      if (sha256 is! String || bytes is! num) return;
      _openFlash(
        FlashTarget.hosted(
          jobId: job,
          sha256: sha256,
          bytes: bytes.toInt(),
          selection: selectionMap,
          label: label,
        ),
        back: AppPage.output,
      );
      return;
    }
    final output = request?['output'];
    if (output is! Map) return;
    _openFlash(
      FlashTarget(
        job: job,
        store: Map<String, Object?>.from(output),
        selection: selectionMap,
        label: label,
      ),
      back: AppPage.output,
    );
  }

  String? get _flashUnavailable {
    if (_build.result == null) return 'Build a package before flashing it.';
    if (_build.request?['selection'] is! Map) {
      return 'The build request has no selection to reopen.';
    }
    if (_build.result?['hosted'] == true) {
      final sha256 = _build.result?['sha256'];
      final bytes = _build.result?['bytes'];
      if (sha256 is! String || bytes is! num) {
        return 'The hosted result has no digest and length to flash.';
      }
    } else if (_build.request?['output'] is! Map) {
      return 'The build request has no store to reopen.';
    }
    if (!widget.environment.has('usb.web')) {
      return 'This browser context reports no WebUSB support (usb.web). '
          'Open the app in a current Chromium browser over HTTPS or '
          'localhost.';
    }
    return null;
  }

  void _startBuild() {
    final request = _setup.buildRequest();
    if (request == null) return;
    final summary = Map<String, Object?>.from(_setup.packageSummary);
    final zip = _setup.zipOutput;
    setState(() {
      _hasOutput = true;
      _page = AppPage.output;
    });
    unawaited(_build.start(request: request, summary: summary, zip: zip));
  }

  @override
  void dispose() {
    _setup.dispose();
    _build.dispose();
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
      AppPage.setup => SetupPage(setup: _setup, onBuild: _startBuild),
      AppPage.output => AnimatedBuilder(
        animation: _build,
        builder: (context, _) => BuildOutputPage(
          controller: _build,
          onBack: () => _navigate(AppPage.setup),
          onFlash: _flashUnavailable == null ? _flashBuiltPackage : null,
          flashUnavailable: _flashUnavailable,
        ),
      ),
      AppPage.flash => FlashPage(
        controller: _flash!,
        onBack: () => _navigate(_flashBack),
      ),
      AppPage.history => HistoryPage(
        runtime: widget.runtime,
        setup: _setup,
        onFlash: (target) => _openFlash(target, back: AppPage.history),
      ),
      AppPage.environment => EnvironmentPage(
        runtime: widget.runtime,
        tables: widget.tables,
        initial: widget.environment,
      ),
      AppPage.documentation => DocsPage(runtime: widget.runtime),
    };
  }

  String _shortLabel(AppPage page) => switch (page) {
    AppPage.setup => 'New package',
    AppPage.output => 'Build output',
    AppPage.flash => 'Flash',
    AppPage.history => 'History',
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
