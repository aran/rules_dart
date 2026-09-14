import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Runs a `dart_test`'s pre-compiled kernel with asserts enabled.
///
/// `dart_test` compiles the test `main` to a self-contained `.dill` at build
/// time, so this launcher only resolves the VM and the dill from runfiles and
/// runs `dart --enable-asserts <dill>` — there is no package_config or source
/// co-location to do at runtime.
///
/// The VM writes straight to this process's stdio rather than through it, so a
/// test that hangs until Bazel kills it still leaves what it printed in
/// test.log, and the launcher exits with the VM even if the test leaked a
/// process that holds those streams open.
Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final dartKey = env['RULES_DART_DART'];
  final dillKey = env['RULES_DART_DILL'];

  if (dartKey == null || dillKey == null) {
    stderr.writeln('Missing required environment variables.');
    stderr.writeln('  RULES_DART_DART=$dartKey');
    stderr.writeln('  RULES_DART_DILL=$dillKey');
    exit(1);
  }

  final r = Runfiles.create();
  final dart = r.rlocation(dartKey);
  final dill = r.rlocation(dillKey);

  final vm = await Process.start(dart, [
    '--enable-asserts',
    dill,
    ...args,
  ], mode: ProcessStartMode.inheritStdio);
  exit(await vm.exitCode);
}
