import 'package:json_annotation/json_annotation.dart';

part 'wrapper.g.dart';

// Generic wrapper with `genericArgumentFactories: true`. Consumers pass
// a per-T factory at call sites (`Wrapper.fromJson(json, User.fromJson)`)
// so the generator doesn't need to know T concretely. Exercises the
// genericArgumentFactories codegen path which emits accessors taking
// `T Function(Object?)` / `Object Function(T)` arguments.
@JsonSerializable(genericArgumentFactories: true)
class Wrapper<T> {
  Wrapper({required this.data});

  factory Wrapper.fromJson(
    Map<String, dynamic> json,
    T Function(Object? json) fromJsonT,
  ) =>
      _$WrapperFromJson(json, fromJsonT);

  final T data;

  Map<String, dynamic> toJson(Object? Function(T value) toJsonT) =>
      _$WrapperToJson(this, toJsonT);
}
