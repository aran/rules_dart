# dart_no_pubspec

Two packages with no `pubspec.yaml` anywhere, laid out as pub lays a package
out: `app`, whose name and language version a `dart_package_metadata` at its
root states, and `greet`, which states neither. Each package's root is the
directory above its `lib/`, `bin/` and `test/`, as `dart_library` derives it,
so `bin/` files get a `dart_binary` and `test/` files a `dart_test` exactly as
they would beside a pubspec, and `test/`'s relative import into `lib/` resolves
to the library that holds the file.
