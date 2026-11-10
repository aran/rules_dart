import 'package:codegen/event.dart';
import 'package:test/test.dart';

void main() {
  test('freezed then json_serializable roundtrips through JSON', () {
    const event = Event(type: 'click', sequence: 42);
    final json = event.toJson();
    expect(json, {'type': 'click', 'sequence': 42});
    expect(Event.fromJson(json), event);
  });
}
