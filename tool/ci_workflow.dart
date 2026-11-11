/// What `.github/workflows/ci.yaml` says CI runs: the `test` job's folders and
/// command, each job's steps, and the directories its steps run in. CI's file
/// is the one place these are written; tools that mirror CI read them here.
library;

import 'dart:convert';

import 'package:yaml/yaml.dart';

/// The job branch protection gates on: it needs every job that must pass.
const conclusionJob = 'conclusion';

/// The job that runs `bazel test //...` in each of its `folders`.
const testJob = 'test';

/// One step of a job.
final class CiStep {
  CiStep(this.name, this.workingDirectory, this.run);

  /// The step's `name`, or its command when it has none.
  final String name;

  /// The step's `working-directory`, relative to the checkout; `.` when it
  /// gives none.
  final String workingDirectory;

  /// The step's `run` script, or null for a step that `uses` an action.
  final String? run;
}

/// One job of the workflow.
final class CiJob {
  CiJob(this.name, this._job);

  final String name;
  final YamlMap _job;

  /// The jobs this one `needs`.
  List<String> get needs => switch (_job['needs']) {
    null => const [],
    final String one => [one],
    final YamlList many => [for (final n in many) n as String],
    final other => throw FormatException('job `$name`: `needs` is $other'),
  };

  /// Whether a failure of this job leaves the run green
  /// (`continue-on-error: true`).
  bool get nonBlocking => _job['continue-on-error'] == true;

  /// The job's steps, `${{ matrix.<key> }}` in a working directory expanded
  /// into one step per value of that matrix key.
  List<CiStep> get steps => [
    for (final step in (_job['steps'] as YamlList?) ?? YamlList())
      for (final dir in _workingDirectories(step as YamlMap))
        CiStep(
          (step['name'] ?? step['run'] ?? step['uses']) as String,
          dir,
          step['run'] as String?,
        ),
  ];

  /// The `with:` inputs a job that calls a reusable workflow passes.
  YamlMap get inputs => (_job['with'] as YamlMap?) ?? YamlMap();

  List<String> _workingDirectories(YamlMap step) {
    final dir = step['working-directory'] as String?;
    if (dir == null) return const ['.'];
    final expression = RegExp(r'\$\{\{\s*matrix\.([\w-]+)\s*\}\}');
    final match = expression.firstMatch(dir);
    if (match == null) {
      if (dir.contains(r'${{')) {
        throw FormatException(
          'job `$name`: cannot read the working directory `$dir`',
        );
      }
      return [_normalize(dir)];
    }
    final values =
        ((_job['strategy'] as YamlMap?)?['matrix'] as YamlMap?)?[match[1]];
    if (values is! YamlList) {
      throw FormatException(
        'job `$name`: `$dir` names `matrix.${match[1]}`, which is not a list '
        'in the job\'s strategy',
      );
    }
    return [
      for (final value in values)
        _normalize(dir.replaceFirst(match[0]!, value as String)),
    ];
  }
}

/// The workflow in `ci.yaml`'s text.
final class CiWorkflow {
  CiWorkflow.parse(String text) : _root = loadYaml(text) as YamlMap;

  final YamlMap _root;

  /// Every job, in the order the file lists them.
  List<CiJob> get jobs => [
    for (final MapEntry(:key, :value) in (_root['jobs'] as YamlMap).entries)
      CiJob(key as String, value as YamlMap),
  ];

  /// The job called [name].
  CiJob job(String name) => jobs.firstWhere(
    (j) => j.name == name,
    orElse: () => throw StateError('ci.yaml has no `$name` job'),
  );

  /// The folders the `test` job runs its command in.
  List<String> get testFolders => [
    for (final folder in jsonDecode(
      job(testJob).inputs['folders'] as String,
    ) as List<Object?>)
      _normalize(folder as String),
  ];

  /// The command the `test` job runs in each folder.
  String get testCommand => job(testJob).inputs['bazel_test_command'] as String;

  /// The folders where [testCommand] passes when Bazel finds no test target
  /// (exit code 4): those its `case $PWD in */<folder>|...)` names.
  Set<String> get noTestFolders {
    final cases = RegExp(r'case \$PWD in ([^)]*)\)').firstMatch(testCommand);
    if (cases == null) return const {};
    return {
      for (final pattern in cases[1]!.split('|'))
        if (pattern.startsWith('*/'))
          _normalize(pattern.substring(2))
        else
          throw FormatException('cannot read the folder pattern `$pattern`'),
    };
  }

  /// Every directory some job runs Bazel or a step in: the `test` job's
  /// folders and every step's working directory.
  Set<String> get directories => {
    ...testFolders,
    for (final job in jobs)
      for (final step in job.steps) step.workingDirectory,
  };

  /// What is wrong with how the jobs gate a merge: [conclusionJob] must need
  /// every job that a failure should block, and no job whose failure is
  /// allowed.
  List<String> gateProblems() {
    final others = [
      for (final job in jobs)
        if (job.name != conclusionJob) job,
    ];
    final needs = job(conclusionJob).needs.toSet();
    return [
      for (final job in others)
        if (!job.nonBlocking && !needs.contains(job.name))
          'job `${job.name}` is not in `$conclusionJob.needs`, so a merge '
              'does not wait for it',
      for (final job in others)
        if (job.nonBlocking && needs.contains(job.name))
          'job `${job.name}` has `continue-on-error: true` but is in '
              '`$conclusionJob.needs`',
      for (final name in needs)
        if (!others.any((j) => j.name == name))
          '`$conclusionJob.needs` names `$name`, which is not a job',
    ];
  }

  /// The e2e workspaces among [trackedFiles] (the checkout's tracked paths)
  /// that no job runs in. A workspace is a directory under `e2e/` with a
  /// `MODULE.bazel`; one inside another with no `MODULE.bazel.lock` of its
  /// own is a module that workspace depends on, not a workspace.
  List<String> unrunWorkspaces(Iterable<String> trackedFiles) {
    final tracked = trackedFiles.toSet();
    final modules = [
      for (final path in tracked)
        if (path.startsWith('e2e/') && path.endsWith('/MODULE.bazel'))
          path.substring(0, path.length - '/MODULE.bazel'.length),
    ]..sort();
    final workspaces = <String>[];
    for (final dir in modules) {
      final nested = workspaces.any((w) => dir.startsWith('$w/'));
      if (nested && !tracked.contains('$dir/MODULE.bazel.lock')) continue;
      workspaces.add(dir);
    }
    final run = directories;
    return [
      for (final dir in workspaces)
        if (!run.contains(dir)) dir,
    ];
  }
}

String _normalize(String dir) {
  var d = dir;
  while (d.startsWith('./')) {
    d = d.substring(2);
  }
  while (d.endsWith('/') && d.length > 1) {
    d = d.substring(0, d.length - 1);
  }
  return d.isEmpty ? '.' : d;
}
