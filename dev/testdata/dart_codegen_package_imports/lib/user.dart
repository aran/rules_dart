import 'package:json_annotation/json_annotation.dart';

import 'imports.dart';
import 'role.dart';

part 'user.g.dart';

@JsonSerializable()
class User {
  User(this.name, this.role);
  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);
  final String name;
  final Role role;
  String get all => names([this]);
}
