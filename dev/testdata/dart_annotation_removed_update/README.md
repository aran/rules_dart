# dart_annotation_removed_update

Update-style fixture guarding stale codegen-rule deletion via
`GenerateResult.Empty`. When a source loses its codegen annotation,
re-running Gazelle must delete the previously generated macro call
(`macro/`) and the synthesized `dart_codegen` stages (`event/`),
regenerating a plain `dart_library` in their place.

This deletion is limited to macro kinds and the codegen primitives, so
hand-written aggregator targets survive; a `dart_library`, `dart_binary` or
`dart_test` is removed only by the checks that recognise it as Gazelle's (a
helper's test, a stale library, a `lib/` BUILD file, a library of hooks).
`# keep` remains the escape hatch for hand-written codegen rules.
