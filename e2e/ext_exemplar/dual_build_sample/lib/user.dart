import 'package:json_annotation/json_annotation.dart';

part 'user.g.dart';

/// A simple user record. Exercises the common `@JsonSerializable` pipeline:
/// SharedPart shard from json_serializable + combining_builder concatenation.
@JsonSerializable()
class User {
  final String name;
  final int age;
  final List<String>? tags;

  User({required this.name, required this.age, this.tags});

  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);
  Map<String, dynamic> toJson() => _$UserToJson(this);
}
