/// The bench's reading of Bazel's events and the machine's load, and its
/// reports. Nothing here runs Bazel or measures anything.
library;

import 'dart:convert';

import 'package:test/test.dart';

import '../load.dart';
import '../metrics.dart';
import '../report.dart';

/// The events of a real `bazel build` (Bazel 9.3), cut to what the bench reads.
final _events = [
  {
    'started': {'buildToolVersion': '9.3.0'},
  },
  {
    'testSummary': {'overallStatus': 'PASSED'},
  },
  {
    'id': {
      'testSummary': {'label': '//a:b_test'},
    },
    'testSummary': {'overallStatus': 'FAILED'},
  },
  {
    'buildMetrics': {
      'actionSummary': {
        'actionsExecuted': '14',
        'actionData': [
          {'mnemonic': 'DartKernel', 'actionsExecuted': '2'},
          {'mnemonic': 'FileWrite', 'actionsExecuted': '5'},
        ],
        'runnerCount': [
          {'name': 'total', 'count': 14},
          {'name': 'internal', 'count': 10},
          {'name': 'darwin-sandbox', 'count': 3},
          {'name': 'disk cache hit', 'count': 1},
        ],
        'actionCacheStatistics': {'hits': 4, 'misses': 14},
      },
      'timingMetrics': {
        'wallTimeInMs': '4280',
        'analysisPhaseTimeInMs': '4',
        'criticalPathTime': '4.183740876s',
      },
    },
  },
].map(jsonEncode);

void main() {
  group('parseBuildEvents', () {
    final m = parseBuildEvents(_events, wallMs: 5000, exitCode: 3);

    test('reads the timings', () {
      expect(m.wallMs, 5000);
      expect(m.exitCode, 3);
      expect(m.bazelWallMs, 4280);
      expect(m.analysisPhaseMs, 4);
      expect(m.criticalPathMs, 4184);
    });

    test('reads the actions', () {
      expect(m.actionsExecuted, 14);
      expect(m.actionCacheHits, 4);
      expect(m.mnemonics, {'DartKernel': 2, 'FileWrite': 5});
      expect(m.runners, {
        'internal': 10,
        'darwin-sandbox': 3,
        'disk cache hit': 1,
      });
      expect(m.outsideCacheHits, 1);
    });

    test('counts tests by status and reads the Bazel version', () {
      expect(m.tests, {'PASSED': 1, 'FAILED': 1});
      expect(m.failedTests, ['//a:b_test (FAILED)']);
      expect(m.bazelVersion, '9.3.0');
    });

    test('survives a command that wrote no events', () {
      final empty = parseBuildEvents(const [], wallMs: 10, exitCode: 2);
      expect(empty.actionsExecuted, isNull);
      expect(empty.criticalPathMs, isNull);
    });

    test('round-trips through JSON', () {
      final back = RunMetrics.fromJson(
        jsonDecode(jsonEncode(m.toJson())) as Map<String, Object?>,
      );
      expect(back.toJson(), m.toJson());
    });
  });

  test('Spread takes the median, least and greatest', () {
    final odd = Spread.of([3, 1, 2])!;
    expect([odd.median, odd.min, odd.max], [2, 1, 3]);
    expect(Spread.of([4, 1, 2, 3])!.median, 2.5);
    expect(Spread.of([null, 5])!.median, 5);
    expect(Spread.of([null]), isNull);
  });

  group('load', () {
    test('reads Linux and macOS load averages', () {
      expect(parseLoadAverage('0.52 0.58 0.59 1/467 12345\n'), [
        0.52,
        0.58,
        0.59,
      ]);
      expect(parseLoadAverage('{ 18.80 21.20 19.61 }\n'), [18.8, 21.2, 19.61]);
      expect(parseLoadAverage('nonsense'), isNull);
    });

    test('reads ps CPU times', () {
      expect(parseCpuTime('0:00.40'), 0.4);
      expect(parseCpuTime('924:44.59'), closeTo(55484.59, 1e-6));
      expect(parseCpuTime('01:02:03'), 3723);
      expect(parseCpuTime('2-00:00:01'), 172801);
    });

    test('picks out other Bazel servers', () {
      const ps = '''
    1  59:55.48 /sbin/launchd
 5507   1:00.00 bazel(a) -jar /ob/a/install/x/A-server.jar --output_base=/ob/a
 6000   0:30.00 bazel(b) -jar /scratch/ob/pub/install/x/A-server.jar
''';
      expect(parseServerCpu(ps, ['/scratch']), {5507: 60.0});
    });

    test('adds up CPU other servers used, new servers from zero', () {
      expect(cpuBetween({1: 10, 2: 5}, {1: 12, 2: 5, 3: 1.5}), 3.5);
    });

    test('an idle server ticking over is not busy', () {
      const window = Duration(seconds: 3);
      expect(busyServers({1: 10, 2: 5}, {1: 10.01, 2: 5.5, 3: 1}, window), 2);
    });

    test('warns about a busy machine', () {
      StartLoad load(double avg, int busy) => StartLoad(
        cpus: 16,
        loadAverage: [avg, 0, 0],
        otherServers: 3,
        busyOtherServers: busy,
      );
      expect(load(11, 0).warnings, isEmpty);
      expect(load(31.4, 0).warnings.single, contains('31.4 on 16 CPUs'));
      expect(
        load(1, 2).warnings.single,
        contains('2 other Bazel servers were busy'),
      );
    });
  });

  group('reports', () {
    BenchResult result(
      String commit,
      List<int> walls, {
      List<String> warnings = const [],
    }) => BenchResult(
      rulesDart: {'commit': commit, 'dirty': false},
      date: '2026-11-09T00:00:00Z',
      environment: {'cpus': 16, 'bazel_version': '9.3.0'},
      warnings: warnings,
      scenarios: [
        ScenarioResult('pub_body_edit', 'a body edit', [
          for (final w in walls)
            Run(
              parseBuildEvents(_events, wallMs: w, exitCode: 0),
              otherServersCpuSeconds: 0,
            ),
        ]),
      ],
    );

    test('the table gives medians and says the run was clean', () {
      final table = renderTable(result('0123456789abcdef', [3000, 1000, 2000]));
      expect(table, contains('rules_dart 0123456789ab'));
      expect(
        table,
        contains('| pub_body_edit | 2.0 (1.0-3.0) | 4.3 | 4.2 | 14 | 1/2 |'),
      );
      expect(table, contains('No warnings'));
    });

    test('the table lists warnings', () {
      final table = renderTable(result('c', [1000], warnings: ['busy']));
      expect(
        table,
        contains('WARNINGS (c), the timings may be skewed:\n- busy'),
      );
    });

    test('the comparison gives the change in each median', () {
      final cmp = renderComparison(
        result('a', [2000]),
        result('b', [1000], warnings: ['busy']),
      );
      expect(
        cmp,
        contains(
          '| pub_body_edit | 2.0 | 1.0 | -50.0% | 4.2 | 4.2 | +0.0% | 14 | 14 |',
        ),
      );
      expect(cmp, contains('WARNINGS (b)'));
    });

    test('a result round-trips through JSON', () {
      final r = result('a', [1000, 2000]);
      final back = BenchResult.fromJson(
        jsonDecode(jsonEncode(r.toJson())) as Map<String, Object?>,
      );
      expect(renderTable(back), renderTable(r));
    });
  });
}
