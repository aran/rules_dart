# dart_builder_config

Fixture guarding the `# gazelle:dart_builder_config` directive on the
macro fast path: a single-annotation source must get the configured JSON
emitted as the `config` attr on its `<builder>_library` call.
