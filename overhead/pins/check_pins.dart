// Refuses a repository whose MODULE.bazel and GitHub workflows use different
// revisions of overhead.
//
//   bazel run @overhead//pins:check
//
// A repository pins overhead's module with `git_override(commit = ...)` and
// calls its reusable workflows as `uses: <owner>/<repo>/...@<sha>`. Both must
// name the same commit, or CI runs one revision of the policy and the hooks
// another. A `local_path_override` outside the repository is refused too: it
// works only on the machine that has that path.
import 'dart:io';

import 'pins.dart';

Future<void> main(List<String> args) async {
  final repo =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
      Directory.current.path;
  final pin = overheadPin(File('$repo/MODULE.bazel').readAsStringSync());
  final workflows = Directory('$repo/.github/workflows');
  final uses = <Uses>[
    if (workflows.existsSync())
      for (final file
          in workflows.listSync()..sort((a, b) => a.path.compareTo(b.path)))
        if (file is File &&
            (file.path.endsWith('.yaml') || file.path.endsWith('.yml')))
          ...usesIn(
            '.github/workflows/${file.uri.pathSegments.last}',
            file.readAsStringSync(),
          ),
  ];
  final problems = pinProblems(pin, uses);
  problems.forEach(stderr.writeln);
  exit(problems.isEmpty ? 0 : 1);
}
