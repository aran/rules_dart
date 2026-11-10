# dart_external_builder

A builder another module ships, registered by `# gazelle:dart_builder` in the
repository root's BUILD file:

- `person.dart` carries its annotation alone: Gazelle writes its macro,
  loaded from the file the directive names, merging the existing target's
  `srcs` and deleting the target of a source that is gone;
- `user.dart` carries it with `@JsonSerializable`: Gazelle chains its shim
  with json_serializable's, combining both parts into `user.g.dart`;
- the package's build.yaml options for the builder's `key` become its
  `config`.
