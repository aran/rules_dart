// A package split over BUILD files under its `lib/` resolves as one package:
// each part is reachable by its `package:` URI, both in this test's compile and
// in a `dart_binary` built from the same package.
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:subdir_package_fixture/a.dart';
import 'package:subdir_package_fixture/src/model/model.dart';

void main(List<String> args) {
  final failures = <String>[];
  void check(Object? got, Object? want, String what) {
    if (got != want) failures.add('$what: got $got, want $want');
  }

  check(describe(' a '), 'MODEL A', 'describe');
  check(Model('b').toString(), 'model b', 'Model.toString');

  final binary = Runfiles.create().rlocation(args.single);
  final run = Process.runSync(binary, ['c']);
  check(run.exitCode, 0, 'describe exit code (stderr: ${run.stderr})');
  check((run.stdout as String).trim(), 'MODEL C', 'describe output');

  if (failures.isNotEmpty) {
    stderr.writeln(failures.join('\n'));
    exit(1);
  }
}
