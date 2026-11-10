# dart_lang_version_pubspec

The pubspec-derived language version on the multi-annotation codegen path.
With no `# gazelle:dart_language_version` directive, the package's
`dart_package_metadata` takes the lower bound of the pubspec.yaml's
`environment.sdk` (here `^3.11.0` → `"3.11"`), and every rule names it:
`user.dart` (single annotation) the macro, `event.dart` (freezed +
json_serializable) the `dart_codegen` stages, and the package's `dart_library`.
