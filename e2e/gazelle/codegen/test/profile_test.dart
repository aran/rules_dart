import 'package:codegen/profile.dart';
import 'package:test/test.dart';

void main() {
  test('both shards of the combined part work', () {
    final changed = Profile(
      handle: 'ada',
      bio: 'engines',
    ).copyWith(bio: 'looms');
    expect(changed.toJson(), {'handle': 'ada', 'bio': 'looms'});
    expect(Profile.fromJson(changed.toJson()).bio, 'looms');
  });
}
