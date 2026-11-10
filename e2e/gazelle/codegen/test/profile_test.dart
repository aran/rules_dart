import 'package:codegen/profile.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  test('both shards of the combined part work', () {
    final changed = profile.copyWith(bio: 'looms');
    expect(changed.toJson(), {'Handle': 'ada', 'Bio': 'looms'});
    expect(Profile.fromJson(changed.toJson()).bio, 'looms');
  });
}
