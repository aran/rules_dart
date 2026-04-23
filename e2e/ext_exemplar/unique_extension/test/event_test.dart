import 'package:test/test.dart';
import 'package:unique_extension/event.dart';

void main() {
  test('freezed value-equality works on generated class', () {
    final a = Event(type: 'click', sequence: 1);
    final b = Event(type: 'click', sequence: 1);
    final c = Event(type: 'click', sequence: 2);
    expect(a, b);
    expect(a, isNot(c));
  });
}
