import 'package:multi_shard_combining/user.dart';
import 'package:test/test.dart';

void main() {
  test('json_serializable + copy_with shards combine into one .g.dart', () {
    final u = User(id: 1, name: 'Alice');
    // toJson comes from json_serializable
    expect(u.toJson(), {'id': 1, 'name': 'Alice'});
    // copyWith comes from copy_with_extension_gen
    final renamed = u.copyWith(name: 'Bob');
    expect(renamed.id, 1);
    expect(renamed.name, 'Bob');
  });
}
