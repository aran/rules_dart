import 'package:codegen/event.dart';
import 'package:codegen/member.dart';
import 'package:test/test.dart';

void main() {
  test('an annotated library and a plain one import each other', () {
    final member = Member(
      name: 'Ada',
      lastEvent: const Event(type: 'click', sequence: 1),
    );
    expect(member.greeting, 'Hello, Ada');
    final back = Member.fromJson(member.toJson());
    expect((back.name, back.lastEvent.sequence), ('Ada', 1));
  });
}
