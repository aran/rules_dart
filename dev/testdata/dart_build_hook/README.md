# dart_build_hook

A package's `hook/build.dart` is stated as the `build_hook` of the library of
its `lib/`, through a filegroup in `hook/`, so rules_dart fails every binary
and test that reaches the library until its `code_assets` replace the hook.
The `dart_library` an earlier Gazelle made of the hook is deleted. A package
that has Gazelle not see its hook (`# gazelle:exclude hook/build.dart`) states
none.
