import 'package:json_annotation/json_annotation.dart';

// CustomId wraps a raw int; exposed via the @JsonConverter attached to
// the User class. Used by the fieldRename/converter test to prove that
// per-field JsonConverter adapters run correctly during the shim's
// generated fromJson/toJson roundtrip.
class CustomId {
  const CustomId(this.raw);
  final int raw;

  @override
  bool operator ==(Object other) => other is CustomId && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;

  @override
  String toString() => 'CustomId($raw)';
}

class CustomIdConverter implements JsonConverter<CustomId, int> {
  const CustomIdConverter();

  @override
  CustomId fromJson(int json) => CustomId(json);

  @override
  int toJson(CustomId object) => object.raw;
}
