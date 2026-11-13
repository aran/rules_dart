import 'package:json_annotation/json_annotation.dart';
import 'package:json_serializable_fixture/custom_id.dart';
import 'package:json_serializable_fixture/role.dart';

part 'user.g.dart';

// Demonstrates the full json_serializable annotation surface in one
// class:
//   - class-level `fieldRename: FieldRename.snake` rewrites every
//     camelCase field to snake_case in the generated JSON
//   - @JsonKey(name: 'user_id') overrides the class-level rename for one field
//   - @JsonKey(toJson: _isoToJson, fromJson: _isoFromJson) plugs in
//     custom per-field adapters (DateTime ↔ ISO-8601 string)
//   - @CustomIdConverter() registers a reusable JsonConverter<T, S>
//   - @JsonEnum-annotated Role uses `code` instead of the enum name

/// A user exercising the full json_serializable annotation surface.
@JsonSerializable(fieldRename: FieldRename.snake)
class User {
  /// Creates a user.
  User({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.authId,
    required this.role,
    required this.createdAt,
  });

  /// Deserializes a [User] from [json].
  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);

  /// The user's id, renamed to `user_id` on the wire.
  @JsonKey(name: 'user_id')
  final int id;

  /// The user's first name.
  final String firstName;

  /// The user's last name.
  final String lastName;

  /// The user's auth id, via [CustomIdConverter].
  @CustomIdConverter()
  final CustomId authId;

  /// The user's role.
  final Role role;

  /// Creation time, serialized as an ISO-8601 string.
  @JsonKey(toJson: _isoToJson, fromJson: _isoFromJson)
  final DateTime createdAt;

  /// Serializes this user to JSON.
  Map<String, dynamic> toJson() => _$UserToJson(this);
}

String _isoToJson(DateTime v) => v.toUtc().toIso8601String();
DateTime _isoFromJson(String v) => DateTime.parse(v);
