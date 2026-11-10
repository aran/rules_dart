// Writes the bazelrc preset into the checkout it runs in, as
// tools/preset.bazelrc, which the checkout's .bazelrc imports:
//
//   bazel run @overhead//preset              write it
//   bazel run @overhead//preset -- --check   fail if it is out of date
//
// The preset is bazelrc-preset.bzl's, at the version overhead pins, for the
// Bazel the checkout runs: bumping either can change it.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'preset_file.dart';

Future<void> main(List<String> args) async {
  final check = args.length == 2 && args[1] == '--check';
  if (args.isEmpty || (args.length == 2 && !check) || args.length > 2) {
    stderr.writeln('usage: bazel run @overhead//preset [-- --check]');
    exit(2);
  }
  final repo = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (repo == null) {
    stderr.writeln('preset: run me with `bazel run`');
    exit(2);
  }
  final generated = File(Runfiles.create().rlocation(args[0]));
  final want = presetFile(generated.readAsStringSync());
  final file = File('$repo/$presetPath');
  if (check) {
    final stale = staleness(
      file.existsSync() ? file.readAsStringSync() : null,
      want,
    );
    if (stale != null) {
      stderr.writeln('preset: $stale');
      exit(1);
    }
    return;
  }
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(want);
}
