# dart_build_yaml

The `options` the package's `build.yaml` states for a builder become the
`config` of every target Gazelle writes for that builder, as the JSON object
build_runner would hand it: on a macro (`user.dart`, and `store.dart`, whose
`drift_codegen` hands them to each drift stage) and on a stage of a chain
(`event.dart`, where freezed has none). A `# gazelle:dart_builder_config`
directive stating the same options is no disagreement.
A part of the file Gazelle cannot carry (`generate_for`, a builder it writes
no targets for) that a `# gazelle:dart_build_yaml_ignore` names is left out,
and the rest carried.
