# dart_scripts_refused

A Dart file outside `lib/`, `bin/` and `test/` with no top-level `main`, which
no script beside it imports, is in nothing Gazelle could write; the run fails
naming it. A `lib/` below the package's root, `vendor/lib/`, is no package's
lib/ while nothing makes `vendor/` a package, so its files are such files too,
and the error says how to make `vendor/` a package.
