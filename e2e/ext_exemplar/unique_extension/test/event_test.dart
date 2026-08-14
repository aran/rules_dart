import 'package:test/test.dart';
import 'package:unique_extension/event.dart';

// Built behind a function so the invocation can't be const: two identical
// `const Event(...)` literals canonicalize to one object, and freezed's
// generated `==` short-circuits on identity — the structural comparison this
// test exists for would never run.
Event event(int sequence) => Event(type: 'click', sequence: sequence);

void main() {
  test('freezed value-equality works on generated class', () {
    final a = event(1);
    final b = event(1);
    final c = event(2);
    expect(a, b);
    expect(a, isNot(c));
  });
}
