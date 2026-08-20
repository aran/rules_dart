import 'package:json_annotation/json_annotation.dart';

part 'role.g.dart';

// @JsonEnum(valueField: 'code') overrides the default enum serialization
// so values round-trip through the `code` field rather than the enum
// constant's name. Used by User's `role` field.

/// A role serialized by its [code] rather than its name.
@JsonEnum(valueField: 'code')
enum Role {
  /// An administrator.
  admin('ADM'),

  /// A read-only viewer.
  viewer('VWR');

  const Role(this.code);

  /// The wire code this value serializes to.
  final String code;
}
