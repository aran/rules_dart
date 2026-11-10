import 'package:json_annotation/json_annotation.dart';

part 'user.g.dart';

@JsonSerializable()
class User {
  User({required this.name});

  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);

  final String name;

  Map<String, dynamic> toJson() => _$UserToJson(this);
}
