# dart_annotation_removed_update

Update-style fixture guarding stale codegen-rule deletion via
`GenerateResult.Empty`. When a source loses its codegen annotation,
re-running Gazelle must delete the previously generated macro call
(`macro/`) and the synthesized `dart_codegen` stages (`event/`),
regenerating a plain `dart_library` in their place.

Deletion is deliberately limited to macro kinds and the codegen
primitives: `dart_library` / `dart_binary` / `dart_test` are never
deleted so hand-written aggregator targets survive (`# keep` remains
the escape hatch for hand-written codegen rules).
