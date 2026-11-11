# dart_scripts

Dart files in a directory that is no package's `lib/`, `bin/` or `test/`
(`tool/` here) are scripts, as `dart run tool/x.dart` runs them: a
`dart_binary` for each file with a top-level `main`, holding in `srcs` the
files beside it that it imports. A `dart_library` for such a directory, which
`dart_library` refuses outside `lib/`, is deleted.
Every binary there names the `dart_package_metadata` of the package at the
root, whose `pubspec.yaml` roots `tool/` too.
