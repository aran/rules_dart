import 'package:test/test.dart';

/// What `test_runner_test` runs through its launcher as a test under
/// `package:test`'s runner. Run on its own, it passes.
void main() {
  test('runs under the runner', () => expect(1 + 1, 2));
}
