import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Runs a `dart_test`'s pre-compiled kernel with asserts enabled.
///
/// `dart_test` compiles the test `main` to a self-contained `.dill` at build
/// time, so this launcher only resolves the VM and the dill from runfiles and
/// runs `dart --enable-asserts <dill>` — there is no package_config or source
/// co-location to do at runtime.
void main(List<String> args) {
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

  final result = Process.runSync(
    dart,
    ['--enable-asserts', dill, ...args],
    stderrEncoding: systemEncoding,
    stdoutEncoding: systemEncoding,
  );

  stdout.write(result.stdout);
  stderr.write(result.stderr);
  exit(result.exitCode);
}
