# Gazelle dual-build coexistence

Fixture for the rules_dart coexistence property: when a user's source tree has
stale `build_runner`-generated files checked in (e.g. `lib/user.g.dart`,
`lib/user.freezed.dart`), Gazelle must regenerate BUILDs cleanly — emitting the
right codegen macro and leaving the stale files out of every `srcs` attribute.

Wired into `gazelle_generation_test` via the existing `dev/testdata/**`
filegroup; the test harness runs Gazelle against this fixture and diffs the
generated BUILDs against the `BUILD.out` goldens.
