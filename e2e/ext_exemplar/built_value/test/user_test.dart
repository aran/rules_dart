import 'package:built_value_sample/user.dart';
import 'package:test/test.dart';

void main() {
  test('built_value generates builder + equality + hashCode', () {
    final alice = User((b) => b
      ..id = 'alpha'
      ..name = 'Alice'
      ..score = 42);
    expect(alice.id, 'alpha');
    expect(alice.name, 'Alice');
    expect(alice.score, 42);

    final aliceCopy = alice.rebuild((b) => b.score = 42);
    expect(aliceCopy, equals(alice));
    expect(aliceCopy.hashCode, alice.hashCode);

    final aliceModified = alice.rebuild((b) => b.score = 100);
    expect(aliceModified, isNot(equals(alice)));
  });
}
