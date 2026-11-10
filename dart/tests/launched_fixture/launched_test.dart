// Properties of a Dart program built by rules_dart once it is run:
//
// - A program a launcher starts sees the environment its user gave it, not the
//   launcher's internals: a test that runs another `dart_test` must get that
//   target's own code, not the code of the target that started it.
// - Every `dart_binary` compile mode produces something that can be executed as
//   it is, the way `bazel run` and a `data` consumer execute it.
//
// A plain `main` (no `package:test`), so the launcher runs it directly and a
// leaked launcher variable would send a child back into this very program;
// `_reentered` stops that from recursing.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

const _reentered = 'LAUNCHED_TEST_REENTERED';

int _failures = 0;

void _check(bool ok, String what) {
  if (ok) {
    stdout.writeln('ok: $what');
  } else {
    _failures++;
    stderr.writeln('FAIL: $what');
  }
}

void main(List<String> args) {
  if (Platform.environment.containsKey(_reentered)) {
    // A child launcher ran this program instead of its own.
    stdout.writeln('re-entered parent');
    exit(3);
  }
  final r = Runfiles.create();
  // Each argument is `name=rlocationpath`.
  for (final arg in args) {
    final i = arg.indexOf('=');
    final name = arg.substring(0, i);
    final path = r.rlocation(arg.substring(i + 1));
    ProcessResult result;
    try {
      result = Process.runSync(path, [], environment: {_reentered: '1'});
    } on ProcessException catch (e) {
      _check(false, '$name can be executed: $e');
      continue;
    }
    final out = '${result.stdout}'.trim();
    _check(
      result.exitCode == 0 && out == 'child ran',
      '$name runs its own program (exit ${result.exitCode}, '
      'stdout "$out", stderr "${result.stderr}")',
    );
  }
  exit(_failures == 0 ? 0 : 1);
}
