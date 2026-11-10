// Runs actionlint on GitHub workflow files, with the shellcheck overhead pins
// checking their `run:` scripts, so the verdict does not depend on whether
// the machine has a shellcheck of its own.
//
//   bazel run @overhead//lint:actionlint -- [<workflow file>...]
//
// With no files, actionlint lints every workflow under .github/workflows.
// Runs in the checkout `bazel run` was started from, or in the current
// directory when started without Bazel (from .bazel_env/bin, as the hook does).
import 'dart:io';

import 'package:runfiles/runfiles.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'actionlint: expects actionlint and shellcheck runfiles paths',
    );
    exit(2);
  }
  final runfiles = Runfiles.create();
  final actionlint = runfiles.rlocation(args[0]);
  final shellcheck = runfiles.rlocation(args[1]);
  final process = await Process.start(
    actionlint,
    ['-shellcheck', shellcheck, ...args.skip(2)],
    workingDirectory: Platform.environment['BUILD_WORKSPACE_DIRECTORY'],
    mode: ProcessStartMode.inheritStdio,
  );
  exit(await process.exitCode);
}
