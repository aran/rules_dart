// Prints the release notes that the `Changelog:` trailers since the last
// version tag would make, as `cliff.toml` renders them.
//
//   bazel run @overhead//changelog                     the unreleased notes
//   bazel run @overhead//changelog -- --tag vX.Y.Z     under that version
//
// Further arguments go to git-cliff. Runs in the checkout `bazel run` was
// started from, so it reads that repository's history.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('preview: expects git-cliff and cliff.toml runfiles paths');
    exit(2);
  }
  final runfiles = Runfiles.create();
  final gitCliff = runfiles.rlocation(args[0]);
  final config = runfiles.rlocation(args[1]);
  final repo = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (repo == null) {
    stderr.writeln('preview: run me with `bazel run`');
    exit(2);
  }
  final process = await Process.start(gitCliff, [
    '--workdir',
    repo,
    '--repository',
    repo,
    '--config',
    config,
    '--unreleased',
    '--strip',
    'header',
    ...args.skip(2),
  ], mode: ProcessStartMode.inheritStdio);
  exit(await process.exitCode);
}
