// Checks that CI gates a merge on every job that must pass, and that some job
// runs in every e2e workspace.
//
//   bazel run //tool:ci_check
import 'dart:io';

import 'ci_workflow.dart';

final _repo =
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ?? Directory.current.path;

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    stderr.writeln('usage: ci_check');
    exit(2);
  }
  final listing = await Process.run('git', [
    'ls-files',
    '-z',
  ], workingDirectory: _repo);
  if (listing.exitCode != 0) {
    stderr.writeln('ci_check: git ls-files failed: ${listing.stderr}');
    exit(2);
  }
  const path = '.github/workflows/ci.yaml';
  final workflow = CiWorkflow.parse(File('$_repo/$path').readAsStringSync());
  final problems = [
    ...workflow.gateProblems(),
    for (final dir in workflow.unrunWorkspaces(
      (listing.stdout as String).split('\x00'),
    ))
      'no job runs in `$dir`: add it to the `$testJob` job\'s `folders`, or '
          'give a step `working-directory: $dir`',
  ];
  if (problems.isEmpty) {
    stdout.writeln('ok     $path');
    return;
  }
  for (final problem in problems) {
    stderr.writeln('$path: $problem');
  }
  exit(1);
}
