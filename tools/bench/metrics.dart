/// What one measured Bazel command cost, read from its Build Event Protocol
/// file, and the summaries over several runs.
library;

import 'dart:convert';

/// The cost of one measured Bazel command.
class RunMetrics {
  RunMetrics({
    required this.wallMs,
    required this.exitCode,
    this.bazelWallMs,
    this.criticalPathMs,
    this.analysisPhaseMs,
    this.actionsExecuted,
    this.actionCacheHits,
    this.mnemonics = const {},
    this.runners = const {},
    this.tests = const {},
    this.failedTests = const [],
    this.bazelVersion,
    this.profile,
  });

  /// Wall time of the whole `bazel` command, as the bench timed it.
  final int wallMs;
  final int exitCode;

  /// Wall time of the command as Bazel counts it, excluding client start-up
  /// and anything a wrapper did before Bazel ran.
  final int? bazelWallMs;
  final int? criticalPathMs;
  final int? analysisPhaseMs;
  final int? actionsExecuted;
  final int? actionCacheHits;

  /// Actions executed, by mnemonic.
  final Map<String, int> mnemonics;

  /// Actions executed, by the strategy that ran them (`darwin-sandbox`,
  /// `worker`, `disk cache hit`, ...), without the `total` row.
  final Map<String, int> runners;

  /// Test targets, by overall status (`PASSED`, `FAILED`, ...).
  final Map<String, int> tests;

  /// The test targets that did not pass.
  final List<String> failedTests;
  final String? bazelVersion;

  /// The `--profile` file of the command, for `bazel analyze-profile`.
  final String? profile;

  /// Actions whose result came from a disk or remote cache rather than from
  /// running them or this output base's own action cache.
  int get outsideCacheHits => runners.entries
      .where((e) => e.key.contains('cache hit'))
      .fold(0, (sum, e) => sum + e.value);

  Map<String, Object?> toJson() => {
    'wall_ms': wallMs,
    'exit_code': exitCode,
    'bazel_wall_ms': bazelWallMs,
    'critical_path_ms': criticalPathMs,
    'analysis_phase_ms': analysisPhaseMs,
    'actions_executed': actionsExecuted,
    'action_cache_hits': actionCacheHits,
    'mnemonics': mnemonics,
    'runners': runners,
    'tests': tests,
    'failed_tests': failedTests,
    'bazel_version': bazelVersion,
    'profile': profile,
  };

  static RunMetrics fromJson(Map<String, Object?> json) => RunMetrics(
    wallMs: json['wall_ms'] as int,
    exitCode: json['exit_code'] as int,
    bazelWallMs: json['bazel_wall_ms'] as int?,
    criticalPathMs: json['critical_path_ms'] as int?,
    analysisPhaseMs: json['analysis_phase_ms'] as int?,
    actionsExecuted: json['actions_executed'] as int?,
    actionCacheHits: json['action_cache_hits'] as int?,
    mnemonics: _intMap(json['mnemonics']),
    runners: _intMap(json['runners']),
    tests: _intMap(json['tests']),
    failedTests: (json['failed_tests'] as List<Object?>? ?? const [])
        .cast<String>(),
    bazelVersion: json['bazel_version'] as String?,
    profile: json['profile'] as String?,
  );
}

Map<String, int> _intMap(Object? json) => {
  for (final e in (json as Map<String, Object?>? ?? {}).entries)
    e.key: e.value as int,
};

/// Reads the metrics of one command from the lines of its
/// `--build_event_json_file`.
RunMetrics parseBuildEvents(
  Iterable<String> lines, {
  required int wallMs,
  required int exitCode,
  String? profile,
}) {
  Map<String, Object?>? metrics;
  String? version;
  final tests = <String, int>{};
  final failedTests = <String>[];
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final event = jsonDecode(line) as Map<String, Object?>;
    if (event['buildMetrics'] case final Map<String, Object?> m
        when m.isNotEmpty) {
      metrics = m;
    }
    if (event['started'] case final Map<String, Object?> started) {
      version = started['buildToolVersion'] as String?;
    }
    if (event['testSummary'] case final Map<String, Object?> summary) {
      final status = summary['overallStatus'] as String? ?? 'UNKNOWN';
      tests[status] = (tests[status] ?? 0) + 1;
      if (status != 'PASSED') {
        final id = event['id'] as Map<String, Object?>?;
        final label = (id?['testSummary'] as Map<String, Object?>?)?['label'];
        failedTests.add('${label ?? '?'} ($status)');
      }
    }
  }
  final timing = metrics?['timingMetrics'] as Map<String, Object?>?;
  final actions = metrics?['actionSummary'] as Map<String, Object?>?;
  final cache = actions?['actionCacheStatistics'] as Map<String, Object?>?;
  return RunMetrics(
    wallMs: wallMs,
    exitCode: exitCode,
    bazelWallMs: _int(timing?['wallTimeInMs']),
    criticalPathMs: _durationMs(timing?['criticalPathTime']),
    analysisPhaseMs: _int(timing?['analysisPhaseTimeInMs']),
    actionsExecuted:
        _int(actions?['actionsExecuted']) ?? (actions == null ? null : 0),
    actionCacheHits: cache == null ? null : _int(cache['hits']) ?? 0,
    mnemonics: {
      for (final a
          in (actions?['actionData'] as List<Object?>? ?? const [])
              .cast<Map<String, Object?>>())
        a['mnemonic'] as String: _int(a['actionsExecuted']) ?? 0,
    },
    runners: {
      for (final r
          in (actions?['runnerCount'] as List<Object?>? ?? const [])
              .cast<Map<String, Object?>>())
        if (r['name'] != 'total') r['name'] as String: _int(r['count']) ?? 0,
    },
    tests: tests,
    failedTests: failedTests,
    bazelVersion: version,
    profile: profile,
  );
}

/// The BEP writes 64-bit counts as JSON strings and smaller ones as numbers.
int? _int(Object? value) => switch (value) {
  int v => v,
  String v => int.tryParse(v),
  _ => null,
};

/// A protobuf `Duration` in JSON form, such as `"4.183740876s"`.
int? _durationMs(Object? value) {
  if (value is! String || !value.endsWith('s')) return null;
  final seconds = double.tryParse(value.substring(0, value.length - 1));
  return seconds == null ? null : (seconds * 1000).round();
}

/// The median, least and greatest of a metric over a scenario's runs.
class Spread {
  Spread(this.median, this.min, this.max);
  final num median;
  final num min;
  final num max;

  /// The spread of [values], or null when there are none.
  static Spread? of(Iterable<num?> values) {
    final sorted = values.whereType<num>().toList()..sort();
    if (sorted.isEmpty) return null;
    final mid = sorted.length ~/ 2;
    final median = sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
    return Spread(median, sorted.first, sorted.last);
  }
}
