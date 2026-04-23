import 'package:json_annotation/json_annotation.dart';

import 'custom_id.dart';
import 'role.dart';

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
@JsonSerializable(fieldRename: FieldRename.snake)
class User {
  User({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.authId,
    required this.role,
    required this.createdAt,
  });

  @JsonKey(name: 'user_id')
  final int id;
  final String firstName;
  final String lastName;
  @CustomIdConverter()
  final CustomId authId;
  final Role role;
  @JsonKey(toJson: _isoToJson, fromJson: _isoFromJson)
  final DateTime createdAt;

  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);
  Map<String, dynamic> toJson() => _$UserToJson(this);
}

String _isoToJson(DateTime v) => v.toUtc().toIso8601String();
DateTime _isoFromJson(String v) => DateTime.parse(v);
