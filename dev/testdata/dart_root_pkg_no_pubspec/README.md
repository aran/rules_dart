# dart_root_pkg_no_pubspec

Annotated sources in the workspace ROOT directory with no `pubspec.yaml` and
no `# gazelle:dart_package_name` directive — the one arrangement where the
codegen rules and the package's `dart_library` could name different packages.
The codegen sites take the name from `libraryName`, which falls back to `"lib"`
at the root; the library, named `lib` from the same function, omits
`package_name` and `dart_library` derives it from the target's name instead. `codegen_identity_error` fails a build whose
two halves disagree, so what Gazelle emits here has to be self-consistent.
