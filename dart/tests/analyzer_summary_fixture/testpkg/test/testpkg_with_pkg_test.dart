// The same check as testpkg_test.dart, written for the `test` package: this
// test depends on it, so it has a test to run.
import 'package:test/test.dart';
import 'package:testpkg_fixture/testpkg.dart';

void main() {
  test('the library of the package is reachable from its own test', () {
    expect(testpkgValue(), 'value');
  });
}
