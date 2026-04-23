## dart_multi_annotation_chain

Fixture guarding the multi-annotation pipeline path in `GenerateRules`.

A single source file carrying both `@Freezed` (non-SharedPart,
`.freezed.dart`) and `@JsonSerializable` (SharedPart → combining)
must produce: one `dart_codegen` for freezed, one `dart_codegen` for
the json_serializable SharedPart, a combining `dart_codegen` that
merges the `.g.part` shard into `.g.dart`, and a wrapping
`dart_library` whose `srcs` include the source plus both final
generated files. Regressions in DAG topological ordering or in
`emitCodegenStages`' combining-stage insertion would break the
expected graph.
