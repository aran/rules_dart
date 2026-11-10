import 'package:codegen/codegen.dart';
import 'package:codegen/event.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  test('freezed then json_serializable roundtrips through JSON', () {
    final json = event.toJson();
    expect(json, {'Type': 'click', 'Sequence': 42});
    expect(Event.fromJson(json), event);
  });

  test('the plain library reaches every generated one', () {
    expect(summary(user, profile, event), 'Ada @ada click#42');
  });
}
