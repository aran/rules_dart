import 'package:codegen/user.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  test('json_serializable roundtrips through JSON', () {
    final json = user.toJson();
    expect(json, {'id': 7, 'name': 'Ada'});
    final back = User.fromJson(json);
    expect((back.id, back.name), (7, 'Ada'));
  });
}
