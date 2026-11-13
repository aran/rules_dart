// Checks `.github/workflows/ci.yaml` against the repository it runs in: that
// the `conclusion` job, which branch protection requires, gates on every job
// that must pass, and that some job runs in every Bazel workspace.
//
//   bazel run @overhead//ci:check
//
// The workspaces are those `@overhead//locks:check` keeps a lock for
// (`locks/lock_workspaces.dart`). A job runs in the folders of its `folders`
// input (bazel-contrib's `bazel.yaml`) and in its steps' working directories,
// `${{ matrix.<key> }}` expanded over a matrix the file lists.
import 'dart:io';

import 'package:overhead_ci/ci_workflow.dart';

import '../locks/lock_workspaces.dart';

final _repo =
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ?? Directory.current.path;

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    stderr.writeln('usage: check');
    exit(2);
  }
  final listing = await Process.run('git', [
    'ls-files',
    '-z',
  ], workingDirectory: _repo);
  if (listing.exitCode != 0) {
    stderr.writeln('ci: git ls-files failed: ${listing.stderr}');
    exit(2);
  }
  final rootModule = File('$_repo/MODULE.bazel');
  final workspaces = findWorkspaces(
    (listing.stdout as String).split('\x00').where((p) => p.isNotEmpty),
    rootOverrides: rootModule.existsSync()
        ? localPathOverrides(rootModule.readAsStringSync())
        : const {},
  );
  const path = '.github/workflows/ci.yaml';
  final List<String> problems;
  try {
    final workflow = CiWorkflow.parse(File('$_repo/$path').readAsStringSync());
    problems = [
      ...workflow.gateProblems(),
      for (final dir in workflow.unrunWorkspaces(workspaces))
        'no job runs in the workspace `$dir`: add it to a job\'s `folders`, '
            'or give a step `working-directory: $dir`',
    ];
  } on FormatException catch (e) {
    stderr.writeln('$path: ${e.message}');
    exit(1);
  }
  if (problems.isEmpty) {
    stdout.writeln('ok     $path');
    return;
  }
  for (final problem in problems) {
    stderr.writeln('$path: $problem');
  }
  exit(1);
}
