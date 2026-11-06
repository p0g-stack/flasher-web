import 'package:flutter/material.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

import 'preferences.dart';
import 'runtime.dart';
import 'shell.dart';
import 'theme.dart';

/// Root widget: loads the upstream tables, environment and preferences, then
/// shows the browser-only application shell.
class FlasherApp extends StatefulWidget {
  const FlasherApp({super.key, required this.runtime});

  final AppRuntime runtime;

  @override
  State<FlasherApp> createState() => _FlasherAppState();
}

final class _Bootstrap {
  const _Bootstrap({
    required this.tables,
    required this.environment,
    required this.preferences,
  });

  final UpstreamTables tables;
  final EnvironmentInfo environment;
  final SetupPreferences preferences;
}

class _FlasherAppState extends State<FlasherApp> {
  late Future<_Bootstrap> _bootstrap = _load();

  Future<_Bootstrap> _load() async {
    final tables = await widget.runtime.loadTables();
    final saved = await widget.runtime.bridge.readPreferences();
    final preferences = saved == null
        ? const SetupPreferences()
        : SetupPreferences.fromJson(saved);
    EnvironmentInfo environment;
    try {
      environment = EnvironmentInfo.fromJson(
        await widget.runtime.service.environment(),
      );
    } on Object {
      environment = EnvironmentInfo.empty;
    }
    return _Bootstrap(
      tables: tables,
      environment: environment,
      preferences: preferences,
    );
  }

  void _retry() {
    setState(() => _bootstrap = _load());
  }

  @override
  void dispose() {
    widget.runtime.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return hostColors(
      (light, dark) => MaterialApp(
        title: 'Flasher Builder',
        debugShowCheckedModeBanner: false,
        theme: themeFor(Brightness.light, light),
        darkTheme: themeFor(Brightness.dark, dark),
        themeMode: ThemeMode.system,
        home: FutureBuilder<_Bootstrap>(
          future: _bootstrap,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _StartupError(
                message: '${snapshot.error}',
                onRetry: _retry,
              );
            }
            final data = snapshot.data;
            if (data == null) return const _StartupLoading();
            return AppShell(
              runtime: widget.runtime,
              tables: data.tables,
              environment: data.environment,
              preferences: data.preferences,
            );
          },
        ),
      ),
    );
  }
}

class _StartupLoading extends StatelessWidget {
  const _StartupLoading();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.layers, size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: 14),
            Text('Flasher Builder', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text('Loading the upstream tables…'),
            const SizedBox(height: 20),
            const SizedBox(
              width: 220,
              child: LinearProgressIndicator(minHeight: 4),
            ),
          ],
        ),
      ),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.error_outline, color: theme.colorScheme.error),
                      const SizedBox(width: 10),
                      Text(
                        'Flasher Builder could not start',
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(message),
                  const SizedBox(height: 8),
                  Text(
                    'The app reads upstream/tables.json from its own origin. '
                    'Check that the snapshot was synced and the edge worker '
                    'is serving it.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
