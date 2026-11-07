import 'dart:io';

import 'config.dart';
import 'errors.dart';
import 'util.dart';

/// A cgroup v2 CPU quota prepared for one build child.
final class CpuLimit {
  const CpuLimit(this.directory);

  final Directory directory;
}

/// Applies a real CPU utilization limit (cgroup v2 `cpu.max`) to each build.
///
/// RLIMIT_CPU only limits total CPU seconds. This limiter requires a delegated
/// cgroup v2 subtree and refuses to start when the host cannot enforce a quota.
final class CpuLimiter {
  CpuLimiter._(
    this.config,
    this.base,
    this.quotaMicros,
    this.periodMicros,
  );

  final HostedConfig config;
  final Directory base;
  final int quotaMicros;
  final int periodMicros;

  static Future<CpuLimiter> open(HostedConfig config) async {
    final root = Directory('/sys/fs/cgroup');
    if (!await root.exists() ||
        !await File(joinPath(root.path, ['cgroup.controllers'])).exists()) {
      throw const HostedConfigException(
        'cgroup v2 is required to enforce HOSTED_CPU_PERCENT; none was found.',
      );
    }
    final own = await _ownCgroup();
    if (config.cgroupRoot == null) {
      throw const HostedConfigException(
        'HOSTED_CGROUP_ROOT is required for a real per-job CPU utilization '
        'limit. Point it at a delegated cgroup v2 subtree that lists cpu and '
        'has no processes of its own.',
      );
    }
    if (own == '/') {
      throw const HostedConfigException(
        'The service runs in the root cgroup; a delegated cgroup v2 subtree '
        'is required.',
      );
    }
    final basePath = config.cgroupRoot!;
    final base = Directory(basePath);
    try {
      await base.create(recursive: true);
    } on Object {
      throw const HostedConfigException(
        'HOSTED_CGROUP_ROOT is not writable. Delegate a cgroup v2 CPU '
        'subtree to this service.',
      );
    }
    try {
      final subtree = File(
        joinPath(base.path, ['cgroup.subtree_control']),
      );
      final current = await subtree.readAsString();
      if (!current.split(RegExp(r'\s+')).contains('cpu')) {
        await subtree.writeAsString('+cpu', flush: true);
      }
    } on Object {
      // The controller check below reports the actionable failure.
    }
    final controllers = await File(
      joinPath(base.path, ['cgroup.controllers']),
    ).readAsString();
    if (!controllers.split(RegExp(r'\s+')).contains('cpu')) {
      throw const HostedConfigException(
        'HOSTED_CGROUP_ROOT does not expose the cpu controller. Enable +cpu '
        'in its cgroup.subtree_control before starting the service.',
      );
    }
    final percent = config.cpuPercent;
    final period = config.cpuPeriodMicros;
    final quota = percent * period ~/ 100;
    if (quota <= 0) {
      throw const HostedConfigException(
        'HOSTED_CPU_PERCENT produces an invalid cgroup CPU quota.',
      );
    }
    final limiter = CpuLimiter._(config, base, quota, period);
    await limiter._probe();
    return limiter;
  }

  Future<CpuLimit> reserve(String jobId) async {
    if (!safeSegment(jobId)) {
      throw const HostedInternalException(
        'job_id_invalid',
        'An internal job id is invalid.',
      );
    }
    final directory = Directory(joinPath(base.path, [jobId]));
    try {
      await directory.create();
      await File(
        joinPath(directory.path, ['cpu.max']),
      ).writeAsString('$quotaMicros $periodMicros', flush: true);
      final applied = (await File(
        joinPath(directory.path, ['cpu.max']),
      ).readAsString()).trim();
      if (applied != '$quotaMicros $periodMicros') {
        throw const HostedException(
          'cpu_limit_refused',
          'The cgroup CPU quota could not be verified.',
          status: 500,
        );
      }
      return CpuLimit(directory);
    } on HostedException {
      await release(CpuLimit(directory));
      rethrow;
    } on Object {
      await release(CpuLimit(directory));
      throw const HostedException(
        'cpu_limit_refused',
        'The cgroup CPU quota could not be applied.',
        status: 500,
      );
    }
  }

  /// Moves [pid] into [limit] before the build does meaningful work.
  Future<void> attach(CpuLimit limit, int pid) async {
    final procs = File(joinPath(limit.directory.path, ['cgroup.procs']));
    try {
      await procs.writeAsString('$pid', flush: true);
      final members = await procs.readAsString();
      if (!members
          .split(RegExp(r'\s+'))
          .where((value) => value.isNotEmpty)
          .contains('$pid')) {
        throw const HostedException(
          'cpu_limit_refused',
          'The build process did not join its CPU cgroup.',
          status: 500,
        );
      }
    } on HostedException {
      rethrow;
    } on Object {
      throw const HostedException(
        'cpu_limit_refused',
        'The build process could not join its CPU cgroup.',
        status: 500,
      );
    }
  }

  Future<void> release(CpuLimit limit) async {
    try {
      if (await limit.directory.exists()) {
        await limit.directory.delete(recursive: true);
      }
    } on Object {
      // An empty cgroup is removed by the next attempt or by the operator.
    }
  }

  Future<void> _probe() async {
    final probe = await reserve('probe-${randomId(bytes: 6)}');
    Process? child;
    try {
      final started = await Process.start('sleep', const ['0.5']);
      child = started;
      await attach(probe, started.pid);
      await started.exitCode;
    } on Object {
      throw const HostedConfigException(
        'CPU cgroup delegation is not usable for child processes.',
      );
    } finally {
      child?.kill(ProcessSignal.sigkill);
      await release(probe);
    }
  }

  static Future<String> _ownCgroup() async {
    final lines = await File('/proc/self/cgroup').readAsLines();
    for (final line in lines) {
      if (line.startsWith('0::')) {
        final value = line.substring(3).trim();
        return value.isEmpty ? '/' : value;
      }
    }
    throw const HostedConfigException(
      'The process is not in a cgroup v2 hierarchy.',
    );
  }


}
