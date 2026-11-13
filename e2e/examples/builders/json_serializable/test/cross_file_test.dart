import 'package:json_serializable_fixture/base.dart';
import 'package:json_serializable_fixture/cross_user.dart';
import 'package:test/test.dart';

void main() {
  test('json_serializable resolves Identifiable from a sibling file', () {
    final u = CrossUser(id: 'alpha', name: 'Alice');
    expect(u, isA<Identifiable>());
    final json = u.toJson();
    expect(json, {'id': 'alpha', 'name': 'Alice'});
    expect(CrossUser.fromJson(json).id, 'alpha');
  });
}
