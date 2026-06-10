# dart_builder_runtime_dep

Fixture guarding the `# gazelle:dart_builder_runtime_dep` directive on
BOTH emission paths:

- macro fast path (`user.dart`, single annotation): the override must be
  emitted as `annotation_dep` on the `<builder>_library` call (only when
  it differs from the shipped default — the default stays implicit);
- multi-annotation pipeline (`event.dart`): the overridden dep must land
  in the affected `dart_codegen` stage's `deps`, while builders without
  an override keep their defaults.
