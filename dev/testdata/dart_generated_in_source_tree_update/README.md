# Gazelle: generated files in the source tree, update path

Companion to `dart_generated_in_source_tree`, exercising the update path:
`BUILD.in` already lists the checked-in `.g.dart` and `.freezed.dart` files in
the package library's `srcs`. Gazelle rewrites `srcs` to drop `user.g.dart`,
which the macro it writes generates, and keeps `user.freezed.dart`, which no
target here produces.
