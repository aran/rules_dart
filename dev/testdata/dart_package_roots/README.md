# dart_package_roots

A Dart file belongs to the innermost package whose root holds it, and the root
is the directory holding the `pubspec.yaml`, as pub roots a package. So
`tool/`, `tool/sub/bin/` and `benchmark/` are in the package at the root, and
their scripts name its `dart_package_metadata`; the relative import of
`../lib/app.dart` from `benchmark/` resolves to its library. `example/`, with
a pubspec of its own, is a package of its own, with its own metadata, which its
`bin/` and `tool/` name. `vendored/`, with no pubspec, is a package because a
`dart_package_metadata` at its root states it, as a pubspec would.

A `# gazelle:dart_language_version` at the root states the version of the
root's package only: its metadata states it, which `tool/`'s scripts name, and `example/` and `vendored/`, packages
of their own, do not, as upstream each package's own pubspec states its
version.
