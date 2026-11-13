import 'package:json_serializable_fixture/custom_id.dart';
import 'package:json_serializable_fixture/role.dart';
import 'package:json_serializable_fixture/user.dart';
import 'package:test/test.dart';

void main() {
  final sample = User(
    id: 42,
    firstName: 'Ada',
    lastName: 'Lovelace',
    authId: const CustomId(9001),
    role: Role.admin,
    createdAt: DateTime.utc(2024, 1, 2, 3, 4, 5),
  );

  test('fieldRename: FieldRename.snake rewrites camelCase field keys', () {
    final json = sample.toJson();
    // `firstName` → `first_name`, `lastName` → `last_name`.
    expect(json['first_name'], 'Ada');
    expect(json['last_name'], 'Lovelace');
    // Sanity: camelCase keys are not emitted.
    expect(json.containsKey('firstName'), isFalse);
    expect(json.containsKey('lastName'), isFalse);
  });

  test('@JsonKey(name:) override wins over the class-level rename', () {
    final json = sample.toJson();
    // `@JsonKey(name: 'user_id')` on `id` beats FieldRename.snake's
    // would-be `id` key.
    expect(json['user_id'], 42);
    expect(json.containsKey('id'), isFalse);
  });

  test('@JsonConverter runs on the annotated field', () {
    final json = sample.toJson();
    // authId (type CustomId) serializes to its raw int via CustomIdConverter.
    expect(json['auth_id'], 9001);

    final back = User.fromJson(json);
    expect(back.authId, const CustomId(9001));
  });

  test('@JsonKey(toJson:/fromJson:) wires per-field adapters', () {
    final json = sample.toJson();
    // _isoToJson emits a UTC ISO-8601 string.
    expect(json['created_at'], '2024-01-02T03:04:05.000Z');

    final back = User.fromJson({
      ...json,
      'created_at': '2024-01-02T03:04:05.000Z',
    });
    expect(back.createdAt, DateTime.utc(2024, 1, 2, 3, 4, 5));
  });

  test('@JsonEnum(valueField:) serializes through the configured field', () {
    final json = sample.toJson();
    // Role.admin's `code` is 'ADM'; default enum serialization would
    // emit the name ('admin') instead.
    expect(json['role'], 'ADM');

    final back = User.fromJson({...json, 'role': 'VWR'});
    expect(back.role, Role.viewer);
  });

  test('full roundtrip preserves every field', () {
    final json = sample.toJson();
    final back = User.fromJson(json);
    expect(back.id, 42);
    expect(back.firstName, 'Ada');
    expect(back.lastName, 'Lovelace');
    expect(back.authId, const CustomId(9001));
    expect(back.role, Role.admin);
    expect(back.createdAt, DateTime.utc(2024, 1, 2, 3, 4, 5));
  });
}
