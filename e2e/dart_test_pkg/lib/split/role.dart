part 'role.part.dart';

/// A role. Its `code` comes from a part that only the wrapping library lists,
/// as json_serializable's generated part does.
enum Role {
  /// An administrator.
  admin,

  /// A read-only viewer.
  viewer,
}
