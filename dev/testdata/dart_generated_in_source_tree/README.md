# Gazelle: generated files in the source tree

Fixture for a source tree that holds generated files checked in (for example
`lib/user.g.dart` and `lib/user.freezed.dart`, as a published package ships
them): Gazelle must emit the right codegen macro and leave those files out of
every `srcs` attribute.

Wired into `gazelle_generation_test` via the existing `dev/testdata/**`
filegroup; the test harness runs Gazelle against this fixture and diffs the
generated BUILD files against the `BUILD.out` goldens.
