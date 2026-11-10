import 'package:codegen/codegen.dart';
import 'package:codegen/event.dart';
import 'package:codegen/profile.dart';
import 'package:codegen/user.dart';
import 'package:test/test.dart';

void main() {
  const event = Event(type: 'click', sequence: 42);

  test('freezed then json_serializable roundtrips through JSON', () {
    final json = event.toJson();
    expect(json, {'type': 'click', 'sequence': 42});
    expect(Event.fromJson(json), event);
  });

  test('the plain library reaches every generated one', () {
    final user = User(id: 7, name: 'Ada');
    final profile = Profile(handle: 'ada', bio: 'engines');
    expect(summary(user, profile, event), 'Ada @ada click#42');
  });
}
