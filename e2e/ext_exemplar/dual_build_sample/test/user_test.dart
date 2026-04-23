import 'package:dual_build_sample/user.dart';
import 'package:test/test.dart';

void main() {
  // Sanity check on the runfiles-layout property: the source-tree
  // `lib/user.g.dart` is the INTENTIONALLY-WRONG stale fixture (it returns
  // `STALE_NAME`/`-999`/`STALE_TAG`). If Bazel ever serves it instead of the
  // declared codegen output, the explicit anti-leak assertion below fires.
  test('User round-trips through JSON via rules_dart-generated .g.dart', () {
    final original = User(name: 'alice', age: 30, tags: ['admin', 'prod']);
    final json = original.toJson();
    expect(json, {'name': 'alice', 'age': 30, 'tags': ['admin', 'prod']});
    expect(json['name'], isNot('STALE_NAME'),
        reason: 'stale lib/user.g.dart fixture leaked into runfiles');

    final restored = User.fromJson(json);
    expect(restored.name, 'alice');
    expect(restored.age, 30);
    expect(restored.tags, ['admin', 'prod']);
  });

  test('User handles optional tags', () {
    final u = User(name: 'bob', age: 22);
    final json = u.toJson();
    expect(json['tags'], isNull);
    expect(User.fromJson(json).tags, isNull);
  });
}
