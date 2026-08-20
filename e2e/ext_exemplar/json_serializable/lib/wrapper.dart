import 'package:json_annotation/json_annotation.dart';

part 'wrapper.g.dart';

// Generic wrapper with `genericArgumentFactories: true`. Consumers pass
// a per-T factory at call sites (`Wrapper.fromJson(json, User.fromJson)`)
// so the generator doesn't need to know T concretely. Exercises the
// genericArgumentFactories codegen path which emits accessors taking
// `T Function(Object?)` / `Object Function(T)` arguments.

/// A generic wrapper exercising `genericArgumentFactories`.
@JsonSerializable(genericArgumentFactories: true)
class Wrapper<T> {
  /// Wraps [data].
  Wrapper({required this.data});

  /// Deserializes a [Wrapper] from [json] using [fromJsonT] for `T`.
  factory Wrapper.fromJson(
    Map<String, dynamic> json,
    T Function(Object? json) fromJsonT,
  ) =>
      _$WrapperFromJson(json, fromJsonT);

  /// The wrapped value.
  final T data;

  /// Serializes this wrapper using [toJsonT] for `T`.
  Map<String, dynamic> toJson(Object? Function(T value) toJsonT) =>
      _$WrapperToJson(this, toJsonT);
}
