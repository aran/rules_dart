import 'package:json_annotation/json_annotation.dart';

part 'primitive_user.g.dart';

// Intentionally simple — used by the primitives-form target in
// BUILD.bazel to demonstrate the hand-wired dart_codegen + combining
// path. The macro-form target below covers the same annotations via
// `json_serializable_library`.
@JsonSerializable()
class PrimitiveUser {
  PrimitiveUser({required this.id, required this.name});

  final int id;
  final String name;

  factory PrimitiveUser.fromJson(Map<String, dynamic> json) =>
      _$PrimitiveUserFromJson(json);
  Map<String, dynamic> toJson() => _$PrimitiveUserToJson(this);
}
