import 'package:json_annotation/json_annotation.dart';

part 'role.g.dart';

// @JsonEnum(valueField: 'code') overrides the default enum serialization
// so values round-trip through the `code` field rather than the enum
// constant's name. Used by User's `role` field.
@JsonEnum(valueField: 'code')
enum Role {
  admin('ADM'),
  viewer('VWR');

  const Role(this.code);
  final String code;
}
