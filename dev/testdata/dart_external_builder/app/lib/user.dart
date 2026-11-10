import 'package:greeting/greeting.dart';
import 'package:json_annotation/json_annotation.dart';

part 'user.g.dart';

@Greeting()
@JsonSerializable()
class User {
  final String name;

  User({required this.name});

  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);
}
