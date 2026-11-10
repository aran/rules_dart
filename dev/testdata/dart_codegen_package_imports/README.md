# dart_codegen_package_imports

A package whose sources import each other across annotated and plain files,
in a cycle: `imports.dart` imports `user.dart`, which imports `imports.dart`
back and `role.dart`. The package is one `dart_library`, so the cycle builds.
Each generator sees, in `asset_deps`, the package's files its source reaches
by imports (`src/helper.dart` through `imports.dart`) and what a builder that
runs before its own writes for them (freezed's output for `role.dart`, which
json_serializable reads), and depends in `deps` on the other packages those
files import, never on its own package's library.
