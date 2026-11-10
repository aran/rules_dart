/// A bench result file, its readable table, and the comparison of two.
library;

import 'metrics.dart';

/// One measured command of a scenario.
class Run {
  Run(this.metrics, {required this.otherServersCpuSeconds});

  final RunMetrics metrics;

  /// CPU seconds other Bazel servers used while the command ran.
  final double otherServersCpuSeconds;

  Map<String, Object?> toJson() => {
    ...metrics.toJson(),
    'other_bazel_servers_cpu_s': otherServersCpuSeconds,
  };

  static Run fromJson(Map<String, Object?> json) => Run(
    RunMetrics.fromJson(json),
    otherServersCpuSeconds: (json['other_bazel_servers_cpu_s'] as num)
        .toDouble(),
  );
}

class ScenarioResult {
  ScenarioResult(this.name, this.description, this.runs);

  final String name;
  final String description;
  final List<Run> runs;

  Spread? spread(num? Function(RunMetrics) metric) =>
      Spread.of(runs.map((r) => metric(r.metrics)));

  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'runs': [for (final r in runs) r.toJson()],
  };

  static ScenarioResult fromJson(Map<String, Object?> json) =>
      ScenarioResult(json['name'] as String, json['description'] as String, [
        for (final r in json['runs'] as List<Object?>)
          Run.fromJson(r as Map<String, Object?>),
      ]);
}

class BenchResult {
  BenchResult({
    required this.rulesDart,
    required this.date,
    required this.environment,
    required this.warnings,
    required this.scenarios,
  });

  /// The rules_dart checkout measured: `commit` and `dirty`.
  final Map<String, Object?> rulesDart;
  final String date;

  /// The host, the Bazel version and the load when the bench started.
  final Map<String, Object?> environment;

  /// Everything that may have skewed the run. An empty list is a clean run.
  final List<String> warnings;
  final List<ScenarioResult> scenarios;

  Map<String, Object?> toJson() => {
    'rules_dart': rulesDart,
    'date': date,
    'environment': environment,
    'warnings': warnings,
    'scenarios': [for (final s in scenarios) s.toJson()],
  };

  static BenchResult fromJson(Map<String, Object?> json) => BenchResult(
    rulesDart: json['rules_dart'] as Map<String, Object?>,
    date: json['date'] as String,
    environment: json['environment'] as Map<String, Object?>,
    warnings: (json['warnings'] as List<Object?>).cast<String>(),
    scenarios: [
      for (final s in json['scenarios'] as List<Object?>)
        ScenarioResult.fromJson(s as Map<String, Object?>),
    ],
  );

  String get label {
    final commit = (rulesDart['commit'] as String?) ?? 'unknown';
    final short = commit.length > 12 ? commit.substring(0, 12) : commit;
    return rulesDart['dirty'] == true ? '$short+dirty' : short;
  }
}

String _seconds(num? ms) => ms == null ? '-' : (ms / 1000).toStringAsFixed(1);

String _count(num? n) => n == null ? '-' : n.round().toString();

String _tests(ScenarioResult s) {
  final last = s.runs.last.metrics.tests;
  if (last.isEmpty) return '-';
  final total = last.values.fold(0, (a, b) => a + b);
  return '${last['PASSED'] ?? 0}/$total';
}

/// The result as a Markdown table, medians over the runs, with its warnings.
String renderTable(BenchResult result) {
  final out = StringBuffer()
    ..writeln(
      'rules_dart ${result.label}, ${result.date}, '
      '${result.environment['bazel_version'] ?? 'Bazel ?'}, '
      '${result.environment['cpus']} CPUs, '
      '${result.scenarios.isEmpty ? 0 : result.scenarios.first.runs.length} runs per scenario',
    )
    ..writeln()
    ..writeln(
      '| Scenario | Wall s (min-max) | Bazel wall s | Critical path s | Actions | Tests passed |',
    )
    ..writeln('|---|---|---|---|---|---|');
  for (final s in result.scenarios) {
    final wall = s.spread((m) => m.wallMs);
    out.writeln(
      '| ${s.name} '
      '| ${_seconds(wall?.median)} (${_seconds(wall?.min)}-${_seconds(wall?.max)}) '
      '| ${_seconds(s.spread((m) => m.bazelWallMs)?.median)} '
      '| ${_seconds(s.spread((m) => m.criticalPathMs)?.median)} '
      '| ${_count(s.spread((m) => m.actionsExecuted)?.median)} '
      '| ${_tests(s)} |',
    );
  }
  out.writeln();
  for (final s in result.scenarios) {
    out.writeln('- ${s.name}: ${s.description}');
  }
  out
    ..writeln()
    ..write(_warnings(result));
  return out.toString();
}

String _warnings(BenchResult result) => result.warnings.isEmpty
    ? 'No warnings: the machine was quiet and every run succeeded.\n'
    : 'WARNINGS (${result.label}), the timings may be skewed:\n'
          '${result.warnings.map((w) => '- $w\n').join()}';

String _delta(num? before, num? after) {
  if (before == null || after == null || before == 0) return '-';
  final pct = (after - before) / before * 100;
  return '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(1)}%';
}

/// The medians of [before] and [after], side by side, for the scenarios both
/// measured.
String renderComparison(BenchResult before, BenchResult after) {
  final out = StringBuffer()
    ..writeln('before: rules_dart ${before.label} (${before.date})')
    ..writeln('after:  rules_dart ${after.label} (${after.date})')
    ..writeln()
    ..writeln(
      '| Scenario | Wall s before | after | change | Critical path s before | after | change | Actions before | after |',
    )
    ..writeln('|---|---|---|---|---|---|---|---|---|');
  final afterByName = {for (final s in after.scenarios) s.name: s};
  for (final b in before.scenarios) {
    final a = afterByName[b.name];
    if (a == null) continue;
    num? med(ScenarioResult s, num? Function(RunMetrics) m) =>
        s.spread(m)?.median;
    final wb = med(b, (m) => m.wallMs), wa = med(a, (m) => m.wallMs);
    final cb = med(b, (m) => m.criticalPathMs),
        ca = med(a, (m) => m.criticalPathMs);
    out.writeln(
      '| ${b.name} | ${_seconds(wb)} | ${_seconds(wa)} | ${_delta(wb, wa)} '
      '| ${_seconds(cb)} | ${_seconds(ca)} | ${_delta(cb, ca)} '
      '| ${_count(med(b, (m) => m.actionsExecuted))} | ${_count(med(a, (m) => m.actionsExecuted))} |',
    );
  }
  out.writeln();
  for (final r in [before, after]) {
    if (r.warnings.isNotEmpty) out.write(_warnings(r));
  }
  return out.toString();
}
