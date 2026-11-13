// package:test runs this only in a browser, and `dart test` on the file
// fails on the VM, finding no tests. Gazelle states the browser platforms as
// the test's `target_compatible_with`, so Bazel skips it on the VM.
@TestOn('browser')
library;

import 'package:test/test.dart';

void main() {
  test('runs in a browser', () => fail('ran on the VM'));
}
