# Gazelle dual-build coexistence — update path

Companion to `dual_build_coexistence`, exercising the update path instead of
first-time generation: `BUILD.in` already lists the stale `.g.dart` /
`.freezed.dart` files in `srcs` (as a hand-written or previously-Gazelle-
generated BUILD would, before the filter was in place). Gazelle must rewrite
`srcs` to drop them.
