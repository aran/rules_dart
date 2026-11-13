import 'package:built_value/built_value.dart';

part 'user.g.dart';

/// A minimal built_value model.
abstract class User implements Built<User, UserBuilder> {
  /// Creates a [User] from builder [updates].
  factory User([void Function(UserBuilder) updates]) = _$User;
  User._();

  /// The user's unique id.
  String get id;

  /// The user's display name.
  String get name;

  /// The user's score.
  int get score;
}
