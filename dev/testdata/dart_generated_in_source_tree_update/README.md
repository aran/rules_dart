# Gazelle: generated files in the source tree, update path

Companion to `dart_generated_in_source_tree`, exercising the update path instead
of first-time generation: `BUILD.in` already lists the checked-in `.g.dart` /
`.freezed.dart` files in `srcs` (as a hand-written or previously generated
BUILD would, before the filter was in place). Gazelle must rewrite `srcs` to
drop them.
