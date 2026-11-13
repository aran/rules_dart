/// The scenarios: what a rules_dart user waits for.
library;

import 'bazel.dart';
import 'load.dart';
import 'report.dart';
import 'workspace.dart';

/// Every target of the pub workspace but Gazelle's own, at the root. After
/// `--`, so that the negative patterns are not read as flags.
const _pubTargets = ['--', '//...', '-//:gazelle', '-//:gazelle_bin'];

const _analysis = [
  '--aspects=@rules_dart//dart:analyze.bzl%dart_analyze',
  '--output_groups=dart_analyze',
];

/// What the scenarios share: the two workspaces and the run settings.
class Bench {
  Bench({
    required this.runs,
    required this.pub,
    required this.pubDir,
    required this.pubTests,
    required this.codegen,
    required this.codegenDir,
  });

  final int runs;
  final Bazel pub;
  final String pubDir;

  /// The pub test targets that pass under Bazel (`pub_tests.txt`).
  final List<String> pubTests;
  final Bazel codegen;
  final String codegenDir;

  /// What may have skewed the run, added to as scenarios run.
  final List<String> warnings = [];

  List<String>? _codegenTargets;

  /// The libraries, tests and binaries of `e2e/examples`' builders that
  /// consume generated code, and so build every codegen action behind them;
  /// less those that build C (SQLite), which is not rules_dart's work.
  Future<List<String>> codegenTargets() async =>
      _codegenTargets ??= (await codegen.run('query', [
        'kind("dart_(library|test|binary) rule", '
            'rdeps(//builders/..., kind("codegen rule", //builders/...))) '
            'except rdeps(//builders/..., '
            'kind("cc_.* rule", deps(//builders/...)))',
      ])).split('\n').where((l) => l.trim().isNotEmpty).toList();

  Future<Run> _measure(
    Bazel bazel,
    String label,
    String verb,
    List<String> args, {
    bool cold = false,
  }) async {
    final run = await bazel.measure(label, verb, args);
    final m = run.metrics;
    if (m.exitCode != 0) {
      warnings.add(
        '$label: `bazel $verb` exited ${m.exitCode}'
        '${m.failedTests.isEmpty ? '' : '; failed: ${m.failedTests.join(', ')}'}',
      );
    }
    if (cold && m.outsideCacheHits > 0) {
      warnings.add(
        '$label: ${m.outsideCacheHits} actions came from a disk or '
        'remote cache, so the build was not cold',
      );
    }
    final share = run.otherServersCpuSeconds / (m.wallMs / 1000);
    if (share > busyOtherServersCpuShare) {
      warnings.add(
        '$label: other Bazel servers used '
        '${run.otherServersCpuSeconds.toStringAsFixed(1)} CPU-seconds while it ran',
      );
    }
    return run;
  }

  /// [runs] cold builds: each after `bazel clean` and `bazel shutdown`.
  Future<List<Run>> cold(Bazel bazel, String name, List<String> args) async => [
    for (var i = 1; i <= runs; i++)
      await () async {
        await bazel.coldStart();
        return _measure(bazel, '$name-$i', 'build', args, cold: true);
      }(),
  ];

  /// [runs] rebuilds on a warm server, each after writing [edit]`(i)` to
  /// [file]. Run `i` differs from run `i - 1` the same way the first differs
  /// from the pristine file, so every run measures the same kind of change.
  Future<List<Run>> edited(
    Bazel bazel,
    String name,
    List<String> args,
    EditedFile file,
    String Function(int i) edit,
  ) async {
    await bazel.run('build', args);
    try {
      return [
        for (var i = 1; i <= runs; i++)
          await () {
            file.write(edit(i));
            return _measure(bazel, '$name-$i', 'build', args);
          }(),
      ];
    } finally {
      file.restore();
    }
  }

  EditedFile get pubUtils => EditedFile('$pubDir/lib/src/utils.dart');

  /// A new statement in the body of `pluralize`, in pub's library (`lib/`,
  /// which every other target depends on). Its outline is
  /// unchanged, so its dependents need not recompile.
  String Function(int) bodyEdit(EditedFile utils) =>
      (i) => utils.insertBefore(
        '  if (number == 1) return name;\n',
        '  if (number == -$i) return name;\n',
      );

  /// A new public function in the same library: its outline changes, so
  /// every dependent recompiles.
  String Function(int) apiEdit(EditedFile utils) =>
      (i) =>
          '${utils.pristine}\n/// Added by the bench.\nint benchApi$i() => $i;\n';
}

class Scenario {
  const Scenario(this.name, this.description, this.measure);

  final String name;
  final String description;
  final Future<List<Run>> Function(Bench) measure;

  bool get usesCodegen => name.startsWith('codegen_');
}

final scenarios = [
  Scenario(
    'pub_cold_build',
    'build dart-lang/pub (its library, bin, every test) after clean and shutdown',
    (b) => b.cold(b.pub, 'pub_cold_build', _pubTargets),
  ),
  Scenario(
    'pub_body_edit',
    'rebuild after a body-only edit in pub\'s library',
    (b) {
      final utils = b.pubUtils;
      return b.edited(
        b.pub,
        'pub_body_edit',
        _pubTargets,
        utils,
        b.bodyEdit(utils),
      );
    },
  ),
  Scenario(
    'pub_api_edit',
    'rebuild after adding a public function to pub\'s library',
    (b) {
      final utils = b.pubUtils;
      return b.edited(
        b.pub,
        'pub_api_edit',
        _pubTargets,
        utils,
        b.apiEdit(utils),
      );
    },
  ),
  Scenario(
    'pub_test',
    'bazel test of the pub tests that pass under Bazel, warm, uncached results',
    (b) async {
      await b.pub.run('build', b.pubTests);
      return [
        for (var i = 1; i <= b.runs; i++)
          await b._measure(b.pub, 'pub_test-$i', 'test', [
            '--nocache_test_results',
            ...b.pubTests,
          ]),
      ];
    },
  ),
  Scenario(
    'pub_analysis_cold',
    'the dart_analyze aspect over pub after clean and shutdown (no workers)',
    (b) => b.cold(b.pub, 'pub_analysis_cold', [..._analysis, ..._pubTargets]),
  ),
  Scenario(
    'pub_analysis_warm',
    'the dart_analyze aspect after a body-only edit, workers warm',
    (b) {
      final utils = b.pubUtils;
      return b.edited(
        b.pub,
        'pub_analysis_warm',
        [..._analysis, ..._pubTargets],
        utils,
        b.bodyEdit(utils),
      );
    },
  ),
  Scenario(
    'codegen_cold_build',
    'build e2e/examples\' builders that consume generated code, cold',
    (b) async =>
        b.cold(b.codegen, 'codegen_cold_build', await b.codegenTargets()),
  ),
  Scenario(
    'codegen_edit',
    'rebuild after adding a @JsonSerializable class to an annotated library',
    (b) async {
      final user = EditedFile(
        '${b.codegenDir}/builders/json_serializable/lib/user.dart',
      );
      return b.edited(
        b.codegen,
        'codegen_edit',
        await b.codegenTargets(),
        user,
        (i) => '${user.pristine}\n${_jsonClass('BenchEdit$i')}',
      );
    },
  ),
];

String _jsonClass(String name) =>
    '''
/// Added by the bench.
@JsonSerializable()
class $name {
  /// Creates one.
  $name(this.value);

  /// Deserializes one.
  factory $name.fromJson(Map<String, dynamic> json) => _\$${name}FromJson(json);

  /// A value.
  final int value;

  /// Serializes this.
  Map<String, dynamic> toJson() => _\$${name}ToJson(this);
}
''';
