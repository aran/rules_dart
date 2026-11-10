# Gazelle: generated files in the source tree, update path

Companion to `dart_generated_in_source_tree`, exercising the update path:
`BUILD.in` already lists the checked-in `.g.dart` and `.freezed.dart` files in
the macro's `srcs`. Gazelle rewrites `srcs` to drop `user.g.dart`, which the
macro generates, and puts `user.freezed.dart`, which no target here produces,
in the package's library.
