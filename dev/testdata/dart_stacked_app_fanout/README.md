## dart_stacked_app_fanout

Fixture guarding the `@StackedApp` fan-out path in `GenerateRules`.

`@StackedApp` registers five sub-builders (router / locator / logger /
dialog / bottomsheet). Gazelle must emit one `dart_codegen` target per
sub-builder and the package's `dart_library`, whose `srcs` include
every generated output. Regressions in `buildPipelineForFile` /
`emitCodegen` (e.g. a dropped sub-builder, incorrectly indexed target
names, or a missing `package`) show up here.
