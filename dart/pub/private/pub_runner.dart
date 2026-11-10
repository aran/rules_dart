// The executable of `@rules_dart//dart/pub`: runs `dart pub <args>` with the
// toolchain's SDK, at the root of the workspace `bazel run` was started in.
//
// It is compiled by `dart compile exe` alone, from this file and the runfiles
// library beside it, both of which import only `dart:` libraries: no Dart tool
// rules_dart builds, and so no `pub` repository, takes part. It therefore runs
// while the `pub` extension refuses a lock, the state in which that
// extension's errors tell the user to run it.
import 'dart:io';

import '../../runfiles/lib/runfiles.dart';

/// The runfiles path of the SDK's `dart`, fixed when this was compiled.
const _dart = String.fromEnvironment('rules_dart.pub.dart');

Future<void> main(List<String> args) async {
  final root = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (root == null || root.isEmpty) {
    stderr.writeln(
      'pub: BUILD_WORKSPACE_DIRECTORY is not set; start this with '
      '`bazel run @rules_dart//dart/pub -- <pub arguments>`.',
    );
    exit(2);
  }
  // Under `--noenable_runfiles` (Windows' default) only a manifest is
  // there; it maps `dart` to the SDK's own copy, beside the VM and the
  // snapshots it looks for.
  final String dart;
  try {
    dart = Runfiles.create().rlocation(_dart);
  } on StateError catch (e) {
    stderr.writeln('pub: cannot find the Dart SDK: ${e.message}');
    exit(2);
  }
  if (!File(dart).existsSync()) {
    stderr.writeln(
      'pub: cannot find the Dart SDK: its runfile $_dart resolves to $dart, '
      'which does not exist.',
    );
    exit(2);
  }
  final process = await Process.start(
    dart,
    ['pub', ...args],
    workingDirectory: root,
    // As for every SDK action: the SDK writes no telemetry into the home of
    // the user who runs it.
    environment: {'DASH__SUPPRESS_ANALYTICS': 'true'},
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  // A process a signal ended reports minus the signal; a shell reports 128
  // plus it.
  exit(code < 0 ? 128 - code : code);
}
