/// How busy the machine is, so a run skewed by other work says so.
///
/// Two signals: the load average before the bench starts, and the CPU time
/// other Bazel servers (other output bases) spend while each measured command
/// runs. The second catches another build starting mid-run, which the load
/// average, inflated by the bench's own builds, cannot tell apart.
library;

import 'dart:io';

/// A start-of-run load average per CPU above this is a busy machine: more
/// work is runnable than there are CPUs. Lower bars flag idle machines, as
/// macOS counts threads waiting in the kernel in its load average (measured:
/// a load of 11 on 16 CPUs that were 90% idle).
const busyLoadPerCpu = 1.0;

/// Other Bazel servers using more than this share of one CPU during a
/// measured command were building alongside it.
const busyOtherServersCpuShare = 0.05;

/// The load average and the other Bazel servers when the bench starts.
class StartLoad {
  StartLoad({
    required this.cpus,
    required this.loadAverage,
    required this.otherServers,
    required this.busyOtherServers,
  });

  final int cpus;

  /// The 1, 5 and 15 minute load averages, or null where the platform has
  /// none the bench can read.
  final List<double>? loadAverage;
  final int otherServers;

  /// Other servers that used CPU while the bench sampled them.
  final int busyOtherServers;

  List<String> get warnings => [
    if (loadAverage case final load? when load.first / cpus > busyLoadPerCpu)
      'the 1-minute load average was ${load.first} on $cpus CPUs when the '
          'bench started',
    if (busyOtherServers > 0)
      '$busyOtherServers other Bazel servers were busy when the bench started',
  ];

  Map<String, Object?> toJson() => {
    'cpus': cpus,
    'load_average': loadAverage,
    'other_bazel_servers': otherServers,
    'busy_other_bazel_servers': busyOtherServers,
    'warnings': warnings,
  };
}

/// Samples the machine before the bench starts. [ownOutputBases] are the
/// bench's own servers, which do not count as other work.
Future<StartLoad> sampleStartLoad(List<String> ownOutputBases) async {
  const window = Duration(seconds: 3);
  final before = await otherServerCpu(ownOutputBases);
  await Future<void>.delayed(window);
  final after = await otherServerCpu(ownOutputBases);
  return StartLoad(
    cpus: Platform.numberOfProcessors,
    loadAverage: await _loadAverage(),
    otherServers: after.length,
    busyOtherServers: busyServers(before, after, window),
  );
}

Future<List<double>?> _loadAverage() async {
  if (Platform.isLinux) {
    return parseLoadAverage(File('/proc/loadavg').readAsStringSync());
  }
  if (Platform.isMacOS) {
    final r = await Process.run('sysctl', ['-n', 'vm.loadavg']);
    return r.exitCode == 0 ? parseLoadAverage(r.stdout as String) : null;
  }
  return null;
}

/// Reads the three load averages from `/proc/loadavg` (`0.52 0.58 0.59 ...`)
/// or macOS's `sysctl -n vm.loadavg` (`{ 0.52 0.58 0.59 }`).
List<double>? parseLoadAverage(String text) {
  final numbers = text
      .replaceAll(RegExp('[{}]'), ' ')
      .trim()
      .split(RegExp(r'\s+'))
      .take(3)
      .map(double.tryParse)
      .toList();
  return numbers.length == 3 && numbers.every((n) => n != null)
      ? numbers.cast<double>()
      : null;
}

/// The CPU seconds each running Bazel server outside [ownOutputBases] has
/// used, by process id. Empty where `ps` is unavailable.
Future<Map<int, double>> otherServerCpu(List<String> ownOutputBases) async {
  if (Platform.isWindows) return {};
  final r = await Process.run('ps', ['-A', '-o', 'pid=,time=,command=']);
  if (r.exitCode != 0) return {};
  return parseServerCpu(r.stdout as String, ownOutputBases);
}

/// Picks the Bazel servers out of `ps -A -o pid=,time=,command=` output.
Map<int, double> parseServerCpu(String ps, List<String> ownOutputBases) => {
  for (final line in ps.split('\n'))
    if (RegExp(r'^\s*(\d+)\s+(\S+)\s+(.*)$').firstMatch(line) case final m?
        when m[3]!.contains('A-server.jar') &&
            !ownOutputBases.any(m[3]!.contains))
      int.parse(m[1]!): parseCpuTime(m[2]!),
};

/// Reads `ps`'s cumulative CPU time: `[[dd-]hh:]mm:ss[.ss]` (Linux pads
/// hours, macOS lets minutes run past 59).
double parseCpuTime(String time) {
  var days = 0;
  var rest = time;
  if (rest.contains('-')) {
    final parts = rest.split('-');
    days = int.parse(parts[0]);
    rest = parts[1];
  }
  var seconds = 0.0;
  for (final part in rest.split(':')) {
    seconds = seconds * 60 + double.parse(part);
  }
  return days * 86400 + seconds;
}

/// The servers that used more than [busyOtherServersCpuShare] of a CPU over
/// [window]; an idle server still ticks over now and then.
int busyServers(
  Map<int, double> before,
  Map<int, double> after,
  Duration window,
) => after.entries
    .where(
      (e) =>
          e.value - (before[e.key] ?? 0) >
          busyOtherServersCpuShare * window.inMilliseconds / 1000,
    )
    .length;

/// The CPU seconds other servers used between two [otherServerCpu] samples.
/// A server that started in between counts from zero.
double cpuBetween(Map<int, double> before, Map<int, double> after) =>
    after.entries.fold(0.0, (sum, e) {
      final used = e.value - (before[e.key] ?? 0);
      return sum + (used > 0 ? used : 0);
    });
