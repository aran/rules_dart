import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

// CustomId wraps a raw int; exposed via the @JsonConverter attached to
// the User class. Used by the fieldRename/converter test to prove that
// per-field JsonConverter adapters run correctly during the shim's
// generated fromJson/toJson roundtrip.

/// A value type wrapping a raw int id.
@immutable
class CustomId {
  /// Wraps [raw].
  const CustomId(this.raw);

  /// The wrapped raw id.
  final int raw;

  @override
  bool operator ==(Object other) => other is CustomId && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;

  @override
  String toString() => 'CustomId($raw)';
}

/// Converts [CustomId] to and from its raw int JSON form.
class CustomIdConverter implements JsonConverter<CustomId, int> {
  /// Const-constructible for use in annotations.
  const CustomIdConverter();

  @override
  CustomId fromJson(int json) => CustomId(json);

  @override
  int toJson(CustomId object) => object.raw;
}
