import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'cpu_limiter.dart';
import 'errors.dart';
import 'util.dart';

final class BuildOutcome {
  const BuildOutcome({
    required this.manifest,
    required this.jobName,
    required this.artifactName,
    required this.sha256,
  });

  final Map<String, Object?> manifest;
  final String jobName;
  final String artifactName;
  final String sha256;
}

/// Starts a build child and lets the service observe events and cancel it.
abstract interface class BuildLauncher {
  Future<BuildProcess> start({
    required String jobId,
    required File requestFile,
    required void Function(Map<String, Object?> event) onEvent,
  });
}

/// The subset of a running child the job service needs.
abstract interface class BuildProcess {
  Future<BuildOutcome> finish();

  void kill();
}

/// Starts one native build in a child process under `RLIMIT_CPU`.
final class BuildRunner implements BuildLauncher {
  BuildRunner(this.config, this.cpuLimiter);

  final HostedConfig config;
  final CpuLimiter cpuLimiter;

  String? get _worker => config.buildWorker ?? _defaultWorker();

  /// Verifies the OS limiter and build worker before the server opens a port.
  static Future<void> checkTooling(HostedConfig config) async {
    final worker = config.buildWorker ?? _defaultWorker();
    if (worker == null || !await File(worker).exists()) {
      throw const HostedConfigException(
        'The hosted build worker was not found. Set HOSTED_BUILD_WORKER.',
      );
    }
    if (_defaultWrapper() == null) {
      throw const HostedConfigException(
        'The cgroup stop/continue launcher was not found beside the server.',
      );
    }
    final version = await _run(config.prlimit, ['--version']);
    if (version.exitCode != 0) {
      throw HostedConfigException(
        'HOSTED_PRLIMIT is not usable; CPU limits cannot be enforced.',
      );
    }
    final probe = await _run(config.prlimit, [
      '--cpu=1',
      '--',
      'true',
    ]);
    if (probe.exitCode != 0) {
      throw const HostedConfigException(
        'The OS refused RLIMIT_CPU; the server will not run unbounded.',
      );
    }
  }

  static String? _defaultWorker() {
    final script = File(Platform.script.toFilePath());
    final compiled = File(joinPath(script.parent.path, ['build_worker']));
    if (compiled.existsSync()) return compiled.path;
    final source = File(joinPath(script.parent.path, ['build_worker.dart']));
    if (source.existsSync()) return source.path;
    return null;
  }

  static String? _defaultWrapper() {
    final script = File(Platform.script.toFilePath());
    final compiled = File(joinPath(script.parent.path, ['cgroup_exec']));
    if (compiled.existsSync()) return compiled.path;
    final source = File(joinPath(script.parent.path, ['cgroup_exec.dart']));
    if (source.existsSync()) return source.path;
    return null;
  }

  @override
  Future<RunningBuild> start({
    required String jobId,
    required File requestFile,
    required void Function(Map<String, Object?> event) onEvent,
  }) async {
    final worker = _worker;
    if (worker == null || !await File(worker).exists()) {
      throw const HostedInternalException(
        'build_worker_missing',
        'The build worker is not installed.',
      );
    }
    final wrapper = _defaultWrapper();
    if (wrapper == null) {
      throw const HostedInternalException(
        'cgroup_exec_missing',
        'The cgroup stop/continue launcher is not installed.',
      );
    }
    final limit = await cpuLimiter.reserve(jobId);
    final workerCommand = <String>[];
    if (worker.endsWith('.dart')) {
      workerCommand
        ..add(Platform.resolvedExecutable)
        ..add(worker)
        ..add('--request')
        ..add(requestFile.path);
    } else {
      workerCommand
        ..add(worker)
        ..add('--request')
        ..add(requestFile.path);
    }
    final command = wrapper.endsWith('.dart')
        ? <String>[Platform.resolvedExecutable, wrapper, '--', ...workerCommand]
        : <String>[wrapper, '--', ...workerCommand];
    final Process process;
    try {
      process = await Process.start(
        config.prlimit,
        ['--cpu=${config.cpuSeconds}', '--fsize=${config.jobDiskBytes}', '--', ...command],
        workingDirectory: Directory.current.path,
        environment: {
          ...Platform.environment,
          if (Platform.environment['P0G_NATIVE_LIB'] != null)
            'P0G_NATIVE_LIB': Platform.environment['P0G_NATIVE_LIB']!,
        },
      );
    } on Object {
      await cpuLimiter.release(limit);
      throw const HostedInternalException(
        'build_start_failed',
        'The build process could not start.',
      );
    }
    try {
      await _waitStopped(process.pid);
      await cpuLimiter.attach(limit, process.pid);
      if (!Process.killPid(process.pid, ProcessSignal.sigcont)) {
        throw const HostedInternalException(
          'cgroup_exec_continue_failed',
          'The isolated build process could not be continued.',
        );
      }
    } on Object catch (error) {
      process.kill(ProcessSignal.sigkill);
      final stderrTail = await _startupStderr(process);
      await cpuLimiter.release(limit);
      if (error is HostedException) {
        final detail = stderrTail.trim();
        throw HostedException(
          error.code,
          detail.isEmpty ? error.message : '${error.message} [$detail]',
          status: error.status,
        );
      }
      throw HostedInternalException(
        'build_start_failed',
        stderrTail.trim().isEmpty
            ? 'The build process could not start.'
            : 'The build process could not start [${stderrTail.trim()}]',
      );
    }
    return RunningBuild._(config, process, onEvent, cpuLimiter, limit);
  }

  static Future<String> _startupStderr(Process process) async {
    final buffer = StringBuffer();
    try {
      await process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .forEach((chunk) {
            if (buffer.length < 4096) buffer.write(chunk);
          })
          .timeout(const Duration(seconds: 1));
    } on Object {
      // Diagnostics only; the original startup error is preserved.
    }
    return buffer.toString().replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  }

  static Future<void> _waitStopped(int pid) async {
    final status = File('/proc/$pid/status');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final text = await status.readAsString();
        final match = RegExp(r'^State:\s*(\S+)', multiLine: true).firstMatch(text);
        if (match != null && (match.group(1) == 'T' || match.group(1) == 't')) {
          return;
        }
      } on Object {
        // The process may not have created /proc/<pid>/status yet.
      }
      if (!await _pidAlive(pid)) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw const HostedInternalException(
      'cgroup_exec_not_stopped',
      'The build launcher did not stop before isolation.',
    );
  }

  static Future<bool> _pidAlive(int pid) async {
    try {
      final text = await File('/proc/$pid/status').readAsString();
      return !text.contains('State:\tZ');
    } on Object {
      return false;
    }
  }

  static Future<ProcessResult> _run(
    String executable,
    List<String> arguments,
  ) async {
    try {
      return await Process.run(executable, arguments);
    } on Object {
      return ProcessResult(-1, 0, '', 'not found');
    }
  }
}

/// One running child, its parsed events and its final result.
final class RunningBuild implements BuildProcess {
  RunningBuild._(
    this._config,
    this._process,
    this._onEvent,
    this._cpuLimiter,
    this._cpuLimit,
  ) {
    _stdoutDone = _readStdout();
    _stderrDone = _readStderr();
    _timeout = Timer(_config.jobTimeout, () {
      _timedOut = true;
      _failure ??= const HostedException(
        'build_timeout',
        'The build exceeded the configured time limit.',
        status: 504,
      );
      _kill();
    });
  }

  final HostedConfig _config;
  final Process _process;
  final void Function(Map<String, Object?> event) _onEvent;
  final CpuLimiter _cpuLimiter;
  final CpuLimit _cpuLimit;
  final StringBuffer _stderr = StringBuffer();
  late final Future<void> _stdoutDone;
  late final Future<void> _stderrDone;
  late final Timer _timeout;
  BuildOutcome? _result;
  HostedException? _failure;
  bool _cancelled = false;
  bool _timedOut = false;
  bool _killed = false;

  @override
  void kill() {
    _cancelled = true;
    _kill();
  }

  void _kill() {
    if (_killed) return;
    _killed = true;
    try {
      _process.kill(ProcessSignal.sigkill);
    } on Object {
      // The child may have exited between the check and the signal.
    }
  }

  Future<void> _readStdout() async {
    try {
      await for (final line in _process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())) {
        if (line.isEmpty) continue;
        if (line.length > 1024 * 1024) {
          _failure ??= const HostedInternalException(
            'build_event_oversized',
            'The build process emitted an oversized event.',
          );
          _kill();
          continue;
        }
        Object? decoded;
        try {
          decoded = jsonDecode(line);
        } on FormatException {
          continue;
        }
        if (decoded is! Map<String, dynamic>) continue;
        final event = Map<String, Object?>.from(decoded);
        switch (event['type']) {
          case 'result':
            _result = _parseResult(event);
            break;
          case 'error':
            final message = event['error'];
            if (message is String && message.isNotEmpty) {
              _failure = HostedException(
                'build_failed',
                _publicError(message),
                status: 422,
              );
            }
            break;
          default:
            _onEvent(event);
            break;
        }
      }
    } on Object {
      _failure ??= const HostedInternalException(
        'build_output_failed',
        'The build process output could not be read.',
      );
      _kill();
    }
  }

  Future<void> _readStderr() async {
    try {
      await for (final chunk in _process.stderr.transform(
        const Utf8Decoder(allowMalformed: true),
      )) {
        if (_stderr.length < 65536) _stderr.write(chunk);
      }
    } on Object {
      // Stderr is diagnostic only.
    }
  }

  BuildOutcome? _parseResult(Map<String, Object?> event) {
    final manifest = event['manifest'];
    final job = event['job'];
    final artifact = event['artifact'];
    final sha = event['sha256'];
    final format = event['format'];
    if (manifest is! Map ||
        manifest['artifact'] is! String ||
        job is! String ||
        artifact is! String ||
        sha is! String ||
        format != 'zip') {
      _failure ??= const HostedInternalException(
        'build_result_invalid',
        'The build process returned an invalid result.',
      );
      return null;
    }
    final artifactName = artifact.split(RegExp(r'[/\\]')).last;
    if (!safeSegment(artifactName) ||
        !safeSegment(job) ||
        !isSha256Hex(sha.toLowerCase())) {
      _failure ??= const HostedInternalException(
        'build_result_invalid',
        'The build process returned an invalid artifact name.',
      );
      return null;
    }
    return BuildOutcome(
      manifest: Map<String, Object?>.from(manifest),
      jobName: job,
      artifactName: artifactName,
      sha256: sha.toLowerCase(),
    );
  }

  @override
  Future<BuildOutcome> finish() async {
    final exitCode = await _process.exitCode;
    await Future.wait([_stdoutDone, _stderrDone]);
    _timeout.cancel();
    await _cpuLimiter.release(_cpuLimit);
    final failure = _failure;
    if (failure != null) throw failure;
    if (_timedOut) {
      throw const HostedException(
        'build_timeout',
        'The build exceeded the configured time limit.',
        status: 504,
      );
    }
    if (_cancelled) {
      throw const HostedException(
        'job_cancelled',
        'The build was cancelled.',
        status: 409,
      );
    }
    final result = _result;
    if (exitCode != 0 || result == null) {
      final detail = _stderr.toString().trim();
      if (detail.isNotEmpty) {
        stderr.writeln('hosted build stderr: $detail');
      }
      throw HostedException(
        'build_failed',
        detail.isEmpty
            ? 'The build process failed.'
            : _publicError(detail),
        status: 422,
      );
    }
    return result;
  }

  static String _publicError(String message) {
    final singleLine = message.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (singleLine.length <= 500) return singleLine;
    return singleLine.substring(0, 500);
  }
}
