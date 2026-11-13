/// What a repository's `.github/workflows/ci.yaml` says CI runs: each job's
/// steps and the directories they run in, the folders and command of a job
/// that calls bazel-contrib's `bazel.yaml`, and which jobs gate a merge. CI's
/// file is the one place these are written; tools that mirror CI read them
/// here.
library;

import 'dart:convert';

import 'package:yaml/yaml.dart';

/// The job branch protection gates on: it needs every job that must pass.
const conclusionJob = 'conclusion';

/// One step of a job.
final class CiStep {
  CiStep(this.name, this.workingDirectory, this.run);

  /// The step's `name`, or its command when it has none.
  final String name;

  /// The directory the step runs in, relative to the checkout: its
  /// `working-directory`, or for a `run` step the job's or the workflow's
  /// `defaults.run.working-directory`; `.` when none applies.
  final String workingDirectory;

  /// The step's `run` script, or null for a step that `uses` an action.
  final String? run;
}

/// One job of the workflow.
final class CiJob {
  CiJob(this.name, this._job, this._workflowDefault);

  final String name;
  final YamlMap _job;

  /// The workflow's `defaults.run.working-directory`, or null.
  final String? _workflowDefault;

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

  /// The folders a job calling bazel-contrib's `bazel.yaml` runs its command
  /// in: its `folders` input, a JSON list. Empty for a job without one.
  List<String> get folders => switch (inputs['folders']) {
    null => const [],
    final String json => [
      for (final folder in jsonDecode(json) as List<Object?>)
        _normalize(folder as String),
    ],
    final other => throw FormatException('job `$name`: `folders` is $other'),
  };

  /// The command a job calling bazel-contrib's `bazel.yaml` runs in each of
  /// its [folders]: its `bazel_test_command` input.
  String get bazelTestCommand => switch (inputs['bazel_test_command']) {
    final String command => command,
    _ => throw FormatException('job `$name` has no `bazel_test_command`'),
  };

  /// The [folders] where [bazelTestCommand] passes when Bazel finds no test
  /// target (exit code 4): those its `case $PWD in */<folder>|...)` names.
  Set<String> get noTestFolders {
    final cases = RegExp(r'case \$PWD in ([^)]*)\)')
        .firstMatch(bazelTestCommand);
    if (cases == null) return const {};
    return {
      for (final pattern in cases[1]!.split('|'))
        if (pattern.startsWith('*/'))
          _normalize(pattern.substring(2))
        else
          throw FormatException(
            'job `$name`: cannot read the folder pattern `$pattern`',
          ),
    };
  }

  List<String> _workingDirectories(YamlMap step) {
    final dir =
        step['working-directory'] as String? ??
        (step.containsKey('run')
            ? _defaultDirectory(_job, 'job `$name`') ?? _workflowDefault
            : null);
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
    final matrix = (_job['strategy'] as YamlMap?)?['matrix'];
    final values = matrix is YamlMap ? matrix[match[1]] : null;
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
      CiJob(
        key as String,
        value as YamlMap,
        _defaultDirectory(_root, 'the workflow'),
      ),
  ];

  /// The job called [name].
  CiJob job(String name) => jobs.firstWhere(
    (j) => j.name == name,
    orElse: () => throw StateError('ci.yaml has no `$name` job'),
  );

  /// Every directory some job runs Bazel or a step in: each job's
  /// [CiJob.folders] and every step's working directory.
  Set<String> get directories => {
    for (final job in jobs) ...[
      ...job.folders,
      for (final step in job.steps) step.workingDirectory,
    ],
  };

  /// What is wrong with how the jobs gate a merge: [conclusionJob] must need
  /// every job that a failure should block, and no job whose failure is
  /// allowed.
  List<String> gateProblems() {
    if (!jobs.any((j) => j.name == conclusionJob)) {
      return [
        'no `$conclusionJob` job: add one that `needs` every job a failure '
            'should block, for branch protection to require',
      ];
    }
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

  /// The [workspaces] (directories relative to the checkout root) that no job
  /// runs in.
  List<String> unrunWorkspaces(Iterable<String> workspaces) {
    final run = directories;
    return [
      for (final dir in workspaces)
        if (!run.contains(dir)) dir,
    ];
  }
}

/// The `defaults.run.working-directory` of a workflow or job [node], or null.
String? _defaultDirectory(YamlMap node, String where) {
  final defaults = node['defaults'];
  if (defaults == null) return null;
  final dir = ((defaults as YamlMap)['run'] as YamlMap?)?['working-directory'];
  if (dir == null || dir is String) return dir as String?;
  throw FormatException('$where: `defaults.run.working-directory` is $dir');
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
