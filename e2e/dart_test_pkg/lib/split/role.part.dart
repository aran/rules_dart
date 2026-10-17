part of 'role.dart';

/// The wire code of a [Role].
extension RoleCode on Role {
  /// The name of this role, in capitals.
  String get code => name.toUpperCase();
}
