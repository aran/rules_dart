import 'package:json_serializable_fixture/primitive_user.dart';
import 'package:test/test.dart';

void main() {
  test('primitives-form target round-trips a basic @JsonSerializable class',
      () {
    final u = PrimitiveUser(id: 7, name: 'Ada');
    final json = u.toJson();
    expect(json, {'id': 7, 'name': 'Ada'});

    final back = PrimitiveUser.fromJson(json);
    expect(back.id, 7);
    expect(back.name, 'Ada');
  });
}
