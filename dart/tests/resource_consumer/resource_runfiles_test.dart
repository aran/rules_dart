// Behavioural proof that a dependency's `resources` reach a `dart_test`'s
// runfiles.
//
// This is the run-time half of what `resources` promises. Under pub a package
// directory exists whole on disk, so a package can read a file it shipped; a
// compiled Dart program cannot recover that on its own, because
// `Isolate.resolvePackageUri` returns null with no package_config above the
// binary. Runfiles are the only mechanism that survives compilation, so the
// files have to be staged into them explicitly — and this asserts they are.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  final runfiles = Runfiles.create();
  final path =
      runfiles.rlocation('_main/dart/tests/resource_fixture/lib/strict.yaml');
  final file = File(path);

  if (!file.existsSync()) {
    throw StateError(
      "resource_fixture's lib/strict.yaml is absent from runfiles (looked at "
      '$path). A dependency\'s `resources` did not reach this test — check '
      'that dart_test stages collect_transitive_resources().',
    );
  }

  final content = file.readAsStringSync();
  if (!content.contains('unused_local_variable')) {
    throw StateError(
      'runfiles copy of lib/strict.yaml has unexpected content: $content',
    );
  }

  print('dependency resource reached runfiles ok');
}
