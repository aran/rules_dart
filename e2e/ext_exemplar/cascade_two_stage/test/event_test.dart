import 'package:cascade_two_stage/event.dart';
import 'package:test/test.dart';

void main() {
  test('freezed + json_serializable cascade roundtrips through JSON', () {
    final e = Event(type: 'click', sequence: 42);
    final json = e.toJson();
    expect(json, {'type': 'click', 'sequence': 42});
    final back = Event.fromJson(json);
    expect(back, e);
  });
}
