import 'package:test/test.dart';

/// Cases every implementation must pass, shared by the tests that run them.
void conformance(int Function() subject) {
  test('answers 2', () => expect(subject(), 2));
}
