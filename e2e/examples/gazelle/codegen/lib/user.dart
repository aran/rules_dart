import 'package:json_annotation/json_annotation.dart';

part 'user.g.dart';

/// One builder: Gazelle writes `json_serializable_codegen`.
@JsonSerializable()
class User {
  /// Creates a user.
  User({required this.id, required this.name});

  /// Deserializes a [User] from [json].
  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);

  /// The user's unique id.
  final int id;

  /// The user's display name.
  final String name;

  /// Serializes this user to JSON.
  Map<String, dynamic> toJson() => _$UserToJson(this);
}
