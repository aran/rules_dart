import 'package:json_serializable_fixture/custom_id.dart';
import 'package:json_serializable_fixture/role.dart';
import 'package:json_serializable_fixture/user.dart';
import 'package:json_serializable_fixture/wrapper.dart';
import 'package:test/test.dart';

void main() {
  test(
      'Wrapper<T> with genericArgumentFactories round-trips a nested '
      'User payload via per-T adapters', () {
    final user = User(
      id: 1,
      firstName: 'G',
      lastName: 'H',
      authId: const CustomId(1),
      role: Role.viewer,
      createdAt: DateTime.utc(2024),
    );
    final wrapped = Wrapper<User>(data: user);

    final json = wrapped.toJson((u) => u.toJson());
    // The wrapper's JSON has `data: { nested User JSON }`.
    expect(json['data'], isA<Map<String, dynamic>>());
    expect((json['data'] as Map)['user_id'], 1);

    final back = Wrapper<User>.fromJson(
      json,
      (o) => User.fromJson(o as Map<String, dynamic>),
    );
    expect(back.data.firstName, 'G');
    expect(back.data.role, Role.viewer);
  });
}
