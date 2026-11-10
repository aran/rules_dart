# dart_test_helpers

A file in `test/` that is not a `_test.dart` is a helper, which package:test
never runs: it goes in the `srcs` of each test that reaches it through
relative imports, directly or through another helper, and its imports in that
test's `deps`. It is never a `dart_test` of its own, and the `dart_test` an
earlier Gazelle made of `fixtures.dart` is deleted. A helper in another
directory (`sub/` importing `../fixtures.dart`) cannot be listed, and Gazelle
says so.
