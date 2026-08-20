import 'package:json_annotation/json_annotation.dart';

part 'primitive_user.g.dart';

// Intentionally simple — used by the primitives-form target in
// BUILD.bazel to demonstrate the hand-wired dart_codegen + combining
// path. The macro-form target below covers the same annotations via
// `json_serializable_library`.

/// A serializable user for the primitives-form pipeline.
@JsonSerializable()
class PrimitiveUser {
  /// Creates a user.
  PrimitiveUser({required this.id, required this.name});

  /// Deserializes a [PrimitiveUser] from [json].
  factory PrimitiveUser.fromJson(Map<String, dynamic> json) =>
      _$PrimitiveUserFromJson(json);

  /// The user's unique id.
  final int id;

  /// The user's display name.
  final String name;

  /// Serializes this user to JSON.
  Map<String, dynamic> toJson() => _$PrimitiveUserToJson(this);
}
