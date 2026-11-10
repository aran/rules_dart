# dart_root_pkg_no_pubspec

Annotated sources in the workspace ROOT directory with no `pubspec.yaml` and
no `# gazelle:dart_package_name` directive. A target there naming no
`dart_package_metadata` is named after itself, since the root has no directory
name, so the codegen targets and the package's `dart_library` would name
different packages, which `codegen_identity_error` fails. Gazelle writes a
metadata stating the library's name, `lib`, and every rule names it.
