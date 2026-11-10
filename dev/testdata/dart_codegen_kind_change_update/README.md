# dart_codegen_kind_change_update

A source's codegen targets change kind when its builders change. `event.dart`,
a freezed class with a `fromJson` factory, needs json_serializable too, so the
`freezed_codegen` earlier Gazelle wrote for it becomes a codegen chain:
freezed, json_serializable reading freezed's `.freezed.dart`, and the combining
stage. `user.dart` lost its `@CopyWith`, so its chain becomes a
`json_serializable_codegen`. The package's library lists the new targets'
outputs in place of the old ones.
