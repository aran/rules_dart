# dart_builder_runtime_dep

Fixture guarding the `# gazelle:dart_builder_runtime_dep` directive on
BOTH emission paths:

- macro fast path (`user.dart`, single annotation): the override must be
  emitted as `annotation_dep` on the `<builder>_codegen` call (as any
  runtime package is wherever it differs from the macro's default label);
- multi-annotation pipeline (`event.dart`): the overridden dep must land
  in the affected `dart_codegen` stage's `deps`, while builders without
  an override keep their defaults.

The override replaces the default runtime package: the package's library and
the macro depend on `@my_fork//:json_annotation` alone, though `user.dart`
imports `package:json_annotation`.
