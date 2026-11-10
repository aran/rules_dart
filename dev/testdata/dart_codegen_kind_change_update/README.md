# dart_codegen_kind_change_update

A source's library changes kind when its builders change. `event.dart`, a
freezed class with a `fromJson` factory, needs json_serializable too, so the
`freezed_library` earlier Gazelle wrote for it becomes a codegen chain: freezed,
json_serializable reading freezed's `.freezed.dart`, and the combining stage,
wrapped in a `dart_library`. `user.dart` lost its `@CopyWith`, so its chain
becomes a `json_serializable_library`. Each new library replaces the old one of
the same name.
