import 'dart:io';

import 'package:test/test.dart';

/// What `test_runner_test` runs through its launcher as a test under
/// `package:test`'s runner. Run on its own, it passes.
///
/// With `RUNNER_FIXTURE_EXIT_IF_LOADED=<file>`, the second load of the suite
/// (the file exists by then) ends the VM with `exit(0)` before declaring a
/// test, from the test's own isolate.
void main() {
  final loaded = Platform.environment['RUNNER_FIXTURE_EXIT_IF_LOADED'];
  if (loaded != null) {
    if (File(loaded).existsSync()) exit(0);
    File(loaded).createSync();
  }
  test('runs under the runner', () => expect(1 + 1, 2));
}
