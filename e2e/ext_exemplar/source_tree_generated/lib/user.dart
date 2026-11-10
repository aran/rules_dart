import 'package:json_annotation/json_annotation.dart';

part 'user.g.dart';

/// A simple user record. Exercises the common `@JsonSerializable` pipeline:
/// SharedPart shard from json_serializable + combining_builder concatenation.
@JsonSerializable()
class User {
  /// Creates a user.
  User({required this.name, required this.age, this.tags});

  /// Deserializes a [User] from [json].
  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);

  /// The user's display name.
  final String name;

  /// The user's age in years.
  final int age;

  /// Optional tags attached to the user.
  final List<String>? tags;

  /// Serializes this user to JSON.
  Map<String, dynamic> toJson() => _$UserToJson(this);
}
