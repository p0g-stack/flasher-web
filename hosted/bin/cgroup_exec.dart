import 'dart:io';

/// Stops before running the build so the parent can join this PID to its
/// cgroup, then starts the real worker with inherited stdio.
///
/// This process only contains trusted launcher code; no request-controlled
/// command is executed until after the cgroup move and SIGCONT.
Future<void> main(List<String> arguments) async {
  final separator = arguments.indexOf('--');
  if (separator < 0 || separator + 1 >= arguments.length) {
    stderr.writeln('usage: cgroup_exec -- <command> [args...]');
    exitCode = 64;
    return;
  }
  final stat = await File('/proc/self/stat').readAsString();
  final end = stat.indexOf(' ');
  final pid = int.parse(stat.substring(0, end));
  final stopped = Process.killPid(pid, ProcessSignal.sigstop);
  if (!stopped) {
    stderr.writeln('cgroup_exec: could not stop before isolation');
    exitCode = 70;
    return;
  }
  try {
    final child = await Process.start(
      arguments[separator + 1],
      arguments.sublist(separator + 2),
      mode: ProcessStartMode.inheritStdio,
    );
    exitCode = await child.exitCode;
  } on Object catch (error) {
    stderr.writeln('cgroup_exec: $error');
    exitCode = 70;
  }
}
