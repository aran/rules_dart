# dart_scripts_refused

A Dart file outside `lib/`, `bin/` and `test/` with no top-level `main`, which
no script beside it imports, is in nothing Gazelle could write; the run fails
naming it.
