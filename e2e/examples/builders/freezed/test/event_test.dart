import 'package:freezed_fixture/event.dart';
import 'package:test/test.dart';

void main() {
  test('freezed value class: equality + copyWith + toString', () {
    const a = Event(type: 'click', sequence: 1);
    const b = Event(type: 'click', sequence: 1);
    const c = Event(type: 'click', sequence: 2);

    expect(a, equals(b));
    expect(a, isNot(equals(c)));
    expect(a.hashCode, equals(b.hashCode));

    final bumped = a.copyWith(sequence: 2);
    expect(bumped.sequence, 2);
    expect(bumped.type, a.type);
    expect(a.sequence, 1, reason: 'copyWith must not mutate the source');

    expect(a.toString(), contains('click'));
    expect(a.toString(), contains('1'));
  });
}
