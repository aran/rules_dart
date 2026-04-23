## dart_stacked_app_fanout

Fixture guarding the `@StackedApp` fan-out path in `GenerateRules`.

`@StackedApp` registers five sub-builders (router / locator / logger /
dialog / bottomsheet). Gazelle must emit one `dart_codegen` target per
sub-builder and a single wrapping `dart_library` whose `srcs` include
every generated output. Regressions in `buildPipelineForFile` /
`emitCodegenStages` / `buildAnnotatedLibrary` (e.g. a dropped
sub-builder, mis-indexed target names, or a missing `language_version`
on the wrapper) show up here.
