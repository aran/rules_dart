import 'package:main_fixture/cli.dart';
import 'package:test/test.dart';

// Modular compilation links this library's kernel into the test. Its component carries
// a `main`, and the VM runs the first `main` it finds, so the link must put the test's
// own kernel first.
void main() {
  test('a test runs its own main when it imports a library that has one', () {
    expect(cliName, 'cli');
  });
}
